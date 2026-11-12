// Owns the local `dsh web` process: spawning, adoption, readiness, reconnection and shutdown.
// The log it reads, the two disk records and the visible state live in their own files; this one
// is only the lifecycle wiring between them.

import Foundation

/// Owns the child `dsh web` process: spawning, readiness detection, reconnection and shutdown.
///
/// The access URL printed by the server carries the local auth token, so the controller keeps it
/// in memory and in the mode-0600 session record instead of deriving a URL from the port.
final class ServiceController {
    var onStateChange: ((ServiceState) -> Void)?

    private(set) var state: ServiceState = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    /// Tokenized URL the window should load; `nil` before the server prints it.
    private(set) var accessURL: URL?

    private let preferences: Preferences
    /// Follows the log the service writes itself and reports its banner on the main queue.
    private let logTail = ServiceLogTail()
    private var process: Process?
    private var readinessTimer: Timer?
    private var deadlineTimer: Timer?
    /// Identifies the pending delayed launch, so a newer restart wins.
    private var restartToken = 0
    /// Caps the automatic relaunch after an unexpected child exit at one attempt, so a service that
    /// dies on boot ends in a readable failure instead of a restart loop.
    private var didRelaunchAfterCrash = false
    private var adoptionTimer: Timer?
    /// Watches the service adopted from an earlier launch. It has no `Process` object, so without
    /// this nothing notices it going away and the page retries a dead port for the whole session.
    private var adoptionWatchdog: Timer?
    /// Kernel event source for an adopted service's exit. Process death is reported as it happens;
    /// the timer below only covers the rarer case of a live process that lost its listener.
    private var adoptionExitSource: DispatchSourceProcess?
    /// Consecutive failed port checks of the adopted service; two misses are enough for that case.
    private var adoptedMisses = 0
    private var isStopping = false
    private var adoptedPid: Int32?
    /// Whether `adoptedPid` was proven to be a dsh service before the shell will signal it. A pid
    /// alone is never enough: the kernel reuses numbers, and adoption is what grants permission to
    /// terminate that pid later.
    private var adoptedTrusted = false
    // Dead state: the watchdog closure already captures the port and nothing reads this property.
    // Restore it if teardown ever needs to inspect the adopted listener without the watchdog.
    // private var adoptedPort: Int?

    /// Serializes the reconnect-record writes.
    ///
    /// The launch path publishes one record and the service's banner later republishes it with the
    /// minted token URL; both are background writes, and the file has to end up with the newer one.
    private static let recordQueue = DispatchQueue(label: "com.xu.orca.service-records", qos: .utility)

    /// Longest a launch may stay in `.starting` before the window reports a timeout.
    private static let startupDeadline: TimeInterval = 45
    /// PATH prefix for the login shell: GUI-launched apps do not inherit a terminal PATH.
    private static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// Cadence of the readiness probes after the first, immediate one.
    private static let readinessInterval: TimeInterval = 0.1
    private static let readinessDeadline: TimeInterval = 25
    private static let healthTimeout: TimeInterval = 2
    /// A kept-alive service can still be busy with the previous session's first-screen API calls
    /// when the next launch probes it. One two-second miss used to count as death, after which the
    /// port reclaim killed that very service and threw the whole keep-alive win away.
    private static let adoptionHealthTimeout: TimeInterval = 5
    private static let adoptionHealthAttempts = 3
    private static let adoptionRetryDelay: TimeInterval = 0.5
    private static let adoptionDeadline: TimeInterval = 25
    private static let adoptedWatchdogInterval: TimeInterval = 0.5
    private static let adoptedMissThreshold = 2
    private static let terminationGrace: TimeInterval = 2
    private static let portReleaseTimeout: TimeInterval = 5

    init(preferences: Preferences) {
        self.preferences = preferences
        logTail.onAccessURL = { [weak self] url in
            self?.handleAccessURL(url)
        }
    }

    deinit {
        cancelTimers()
        adoptionWatchdog?.invalidate()
        adoptionExitSource?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the ordered startup chain; a stage that cannot attach hands the launch to its fallback.
    ///
    /// The session record is the only copy of the service's token, so it is not cleared here. A
    /// launch that reaches `.launch` overwrites it from its own banner in `handleAccessURL`, while
    /// an earlier stage may still reuse the listening service that record points at.
    func start() {
        guard process == nil, !state.isStarting else { return }
        didRelaunchAfterCrash = false
        advance(to: .record)
    }

    /// Restarts the service from scratch, discarding the current process.
    ///
    /// The window reports a restart as one continuous progress state: it never passes through the
    /// stopped state, so the splash keeps its spinner instead of offering buttons mid-refresh. The
    /// relaunch is keyed to this call rather than to the visible state, so a state change inside the
    /// wait cannot leave the window spinning with no process and no deadline.
    func restart() {
        restartToken += 1
        let token = restartToken
        didRelaunchAfterCrash = false
        // Read the port before `teardown` forgets the URL the running service was reached on.
        let port = accessURL?.port ?? preferences.port
        state = .starting(preferences.copy.service.restarting)
        teardown()
        // The new server cannot bind until the old listener is gone, so that release — not a fixed
        // pause — is what the relaunch waits on. `teardown` already sent SIGTERM and SIGKILL follows
        // one grace period later, so this always settles; the timeout only bounds a wedged case.
        PortProbe.notifyWhenFree(port: port, within: Self.portReleaseTimeout) { [weak self] in
            guard let self, self.restartToken == token, self.process == nil else { return }
            self.launchOnAvailablePort()
        }
    }

    /// Stops the service and clears both records.
    func stop() {
        teardown()
        state = .idle
    }

    /// Kills the child process and forgets the recorded session without touching the visible state.
    private func teardown() {
        isStopping = true
        stopChild()
        releaseAdopted()
        Self.forgetServiceRecord()
        accessURL = nil
    }

    /// Forgets the private reconnect record and the discoverable endpoint together.
    ///
    /// Only a service that is being stopped, or one confirmed dead, may reach this. An adoption
    /// that merely failed its health check must keep both: the service can still be listening, and
    /// reusing it later is the whole point of keeping it alive. Static so the termination path can
    /// call it from a background queue without retaining the controller.
    private static func forgetServiceRecord() {
        // On the record queue, so a write that is still in flight cannot land on top of the clear and
        // leave a record for a service this launch just let go.
        recordQueue.sync {
            ServiceSessionStore.clear()
            ServiceEndpointStore.clear()
        }
    }

    /// Stops the service for application termination unless the user keeps it alive between launches.
    ///
    /// The wait for the child happens on a background queue and reports back on the main one. It used
    /// to park the main thread on a semaphore for up to two seconds of a quit, which froze AppKit
    /// while the system's own termination watchdog was already running.
    /// - Parameters:
    ///   - grace: seconds to wait for `SIGTERM` before escalating to `SIGKILL`.
    ///   - completion: called on the main queue once the child is gone.
    func shutdown(grace: TimeInterval = 2, completion: @escaping () -> Void = {}) {
        guard !preferences.keepServiceRunningAfterQuit || accessURL == nil else {
            completion()
            return
        }
        isStopping = true
        cancelTimers()
        if adoptedPid != nil {
            releaseAdopted()
            Self.forgetServiceRecord()
        }
        guard let child = detachChild() else {
            Self.forgetServiceRecord()
            logTail.close()
            completion()
            return
        }
        logTail.close()
        if child.isRunning {
            child.terminate()
        }
        // `terminationHandler` reports through the main queue, which is why the wait cannot rely on
        // it: the caller may be that same queue, mid-termination. Polling off the main thread and
        // reporting back keeps the reply honest — the app terminates when the child is really gone.
        let pid = child.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(grace)
            while child.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if child.isRunning {
                kill(pid, SIGKILL)
            }
            ServiceController.forgetServiceRecord()
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Process bookkeeping

    /// Stops the readiness, deadline and adoption timers.
    private func cancelTimers() {
        readinessTimer?.invalidate()
        readinessTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        adoptionTimer?.invalidate()
        adoptionTimer = nil
    }

    /// Detaches the child without signalling it, leaving the caller to decide how.
    ///
    /// Closing the shell's log descriptors is a separate step: the child inherits its own copies,
    /// which is what lets a kept-alive service keep writing after Orca quits.
    @discardableResult
    private func detachChild() -> Process? {
        guard let child = process else { return nil }
        process = nil
        return child
    }

    /// Sends SIGTERM, then SIGKILL if the process is still alive after `grace` seconds.
    private func terminate(_ child: Process, after grace: TimeInterval) {
        if child.isRunning {
            child.terminate()
        }
        let pid = child.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Terminates the process adopted from an earlier launch, if this session has one.
    private func releaseAdopted() {
        stopAdoptionWatchdog()
        let trusted = adoptedTrusted
        // adoptedPort = nil
        guard let pid = adoptedPid else { return }
        adoptedPid = nil
        guard trusted else { return }
        kill(pid, SIGTERM)
    }

    // MARK: - Adopted service

    /// Watches a service adopted from an earlier launch.
    ///
    /// A child this process spawned reports its own exit; an adopted one does not, and that is the
    /// gap that left the page spinning on "reconnecting". The kernel's process-exit event answers
    /// that half immediately instead of inferring death from three misses two seconds apart. The
    /// timer covers only the other failure: a process still alive that lost its listener.
    private func watchAdoptedService(pid: Int32, port: Int) {
        stopAdoptionWatchdog()
        // adoptedPort = port
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, self.adoptedPid == pid else { return }
            self.stopAdoptionWatchdog()
            self.adoptedServiceExited()
        }
        source.activate()
        adoptionExitSource = source
        let timer = runLoopTimer(
            interval: Self.adoptedWatchdogInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self, self.adoptedPid == pid else {
                timer.invalidate()
                return
            }
            if kill(pid, 0) == 0, PortProbe.isInUse(port) {
                self.adoptedMisses = 0
                return
            }
            self.adoptedMisses += 1
            guard self.adoptedMisses >= Self.adoptedMissThreshold else { return }
            self.stopAdoptionWatchdog()
            self.adoptedServiceExited()
        }
        adoptionWatchdog = timer
    }

    /// Stops watching the adopted service and forgets how many probes it has missed.
    private func stopAdoptionWatchdog() {
        adoptionWatchdog?.invalidate()
        adoptionWatchdog = nil
        adoptionExitSource?.cancel()
        adoptionExitSource = nil
        adoptedMisses = 0
        adoptedTrusted = false
    }

    /// Handles a lost adopted service the way a crashed child is handled: relaunch once, then fail.
    ///
    /// The relaunch mints a new token, so the window loads the page again against a live server
    /// instead of leaving the old document retrying a dead one.
    private func adoptedServiceExited() {
        guard !isStopping, adoptedPid != nil else { return }
        adoptedPid = nil
        // adoptedPort = nil
        accessURL = nil
        Self.forgetServiceRecord()
        guard !didRelaunchAfterCrash else {
            state = .failed(preferences.copy.service.previousStopped)
            return
        }
        didRelaunchAfterCrash = true
        ServiceLogTail.note("the adopted local service stopped answering; relaunching once")
        launchOnAvailablePort()
    }

    // MARK: - Startup chain

    /// Runs one startup stage. A stage that cannot attach to a running service hands the launch to
    /// its fallback instead of choosing between two launch paths.
    ///
    /// This replaces the two boolean entry points (`adoptRecordedService` and `reuseServiceOnPort`)
    /// and the `allowReuse` flag: the record, the port owner and a fresh launch were always three
    /// successive steps, not two alternatives. The record read is synchronous because every later
    /// stage needs its answer before it can start; the port-owner lookup and the health probe are
    /// asynchronous, and `.record` starts both at once.
    private func advance(to stage: ServiceStartupStage) {
        switch stage {
        case .record:
            guard let session = recordedSession(), let url = URL(string: session.url) else {
                fallBack(from: .record)
                return
            }
            let port = url.port ?? preferences.port
            // Nothing to adopt when the recorded process is gone and the port is free. Skipping the
            // health window here keeps a stale record from costing seconds on every cold launch.
            guard kill(session.pid, 0) == 0 || PortProbe.isInUse(port) else {
                fallBack(from: .record)
                return
            }
            beginAdoption(url: url, pid: session.pid, port: port)

        case .reuse:
            let port = preferences.port
            guard port > 0, PortProbe.isInUse(port) else {
                fallBack(from: .reuse)
                return
            }
            // Only a verified dsh listener and a real recorded token qualify: nothing here invents
            // a URL or answers "healthy" on the service's behalf.
            guard let session = recordedSession(),
                  let url = URL(string: session.url),
                  url.port == port
            else {
                fallBack(from: .reuse)
                return
            }
            // The lookup walks every process's descriptors, so it runs off the main thread. The
            // generation check keeps a restart made during that window from adopting afterwards.
            let token = restartToken
            resolveListener(on: port) { [weak self] owner, trusted in
                guard let self,
                      self.restartToken == token,
                      self.process == nil,
                      !self.isStopping
                else { return }
                guard let owner, trusted else {
                    self.fallBack(from: .reuse)
                    return
                }
                ServiceLogTail.note("reusing the local service on port \(port) (pid \(owner))")
                self.beginAdoption(url: url, pid: owner, port: port)
            }

        case .launch:
            launchOnAvailablePort()
        }
    }

    /// Hands the launch to the next stage in fallback order.
    private func fallBack(from stage: ServiceStartupStage) {
        guard let next = stage.fallback else { return }
        advance(to: next)
    }

    /// Resolves who owns `port` off the main thread, then answers on the main queue.
    ///
    /// `libproc` walks every process's descriptors and `KERN_PROCARGS2` reads argv; running that
    /// pair inline used to stall the run loop just before `.ready` was published. `trusted` answers
    /// whether argv belongs to a dsh service — it is reported, never invented.
    /// - Parameter fallback: pid used when the kernel reports no listener. Only the adoption path
    ///   supplies it, so a port-owner lookup can never invent an owner from a stale record.
    private func resolveListener(
        on port: Int,
        fallback: Int32? = nil,
        completion: @escaping (Int32?, Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let owner = PortListener.pid(ofListenerOn: port) ?? fallback
            let arguments = owner.flatMap { PortOwner.arguments(of: $0) }
            let trusted = arguments.map { PortOwner.isDshService($0) } ?? false
            DispatchQueue.main.async { completion(owner, trusted) }
        }
    }

    /// Reads the ordered fallback sources synchronously: the private session record first, then the
    /// discoverable endpoint. An earlier source wins by position, not by being more trustworthy.
    ///
    /// The endpoint outlives a failed adoption on purpose: it is the second copy of the token, so
    /// losing `session.json` no longer turns a warm service into an unidentifiable port holder.
    private func recordedSession() -> ServiceSession? {
        let sources: [() -> ServiceSession?] = [
            { ServiceSessionStore.load() },
            { ServiceEndpointStore.load().map { endpoint in
                ServiceSession(
                    pid: endpoint.pid,
                    url: endpoint.url,
                    startedAt: endpoint.issuedAt,
                    processStartedAt: endpoint.processStartedAt
                )
            } }
        ]
        for read in sources {
            if let session = read() { return session }
        }
        return nil
    }

    /// Probes `url` and publishes it as the adopted service only on a genuinely healthy answer.
    ///
    /// A failed probe falls through to `.launch`: once probing has started, the port-owner stage is
    /// already behind us and must not be tried again. Reusing the recorded process keeps the window
    /// origin stable, so the web UI keeps its localStorage state. Identity is settled *after* a real
    /// healthy answer, from the process that actually owns the port — a recorded pid may be stale
    /// after a crash, and signalling an unverified pid is never safe.
    ///
    /// Health and identity are independent questions about the same port, so both are asked at
    /// once: the identity scan used to start only from a healthy reply, which put a whole
    /// global-to-main round trip on the path to `.ready`. Whichever answers last decides the pair.
    private func beginAdoption(url: URL, pid: Int32, port: Int) {
        guard process == nil else { return }
        accessURL = url
        state = .starting(preferences.copy.service.reconnecting)
        var settled = false
        var answers = AdoptionAnswers()
        // The health check outlives a restart decision. Without a generation of its own, its answer
        // arrives after `teardown` has already cleared the adopted service and re-registers it as
        // `.ready` while a fresh child is being launched — two services on one profile.
        restartToken += 1
        let token = restartToken
        // Hands the recorded URL to the window as soon as the port owner is verified.
        //
        // A verified process listening on the port is what the page needs in order to start, and the
        // page's own navigation asks the service for the same document the probe sends. Waiting for
        // that answer before the page could load put the host's longest request in front of the page
        // instead of behind it — 1.2-1.7 s on this machine, against 0.7 s for the whole native launch.
        // The probe still runs and still counts: a listener that never serves the document is a
        // service worth replacing, and it leaves through the same relaunch-once recovery as one that
        // died after being adopted.
        // - Parameter force: settle without an owner answer, i.e. the scan's deadline was reached.
        let settle = { [weak self] (force: Bool) in
            guard let self, !settled else { return }
            guard self.restartToken == token, self.process == nil else { return }
            if let owner = answers.owner, answers.trusted {
                settled = true
                self.adoptionTimer?.invalidate()
                self.adoptionTimer = nil
                self.adoptedTrusted = true
                self.adoptedPid = owner
                self.state = .ready(url)
                self.watchAdoptedService(pid: owner, port: port)
                // After the hand-off: both records serve the *next* launch, and writing them first
                // meant three file operations plus a kernel start-time read in front of the page.
                self.publishEndpoint(url: url, pid: owner)
                return
            }
            // No usable owner: either the scan has not answered yet, or it named a process that is
            // not a dsh service. The first is worth waiting for, the second is not.
            guard force || answers.owner != nil else { return }
            settled = true
            self.adoptionTimer?.invalidate()
            self.adoptionTimer = nil
            self.accessURL = nil
            self.advance(to: .launch)
        }
        // One answer per callback, recorded on the main queue: the probe answers from a URLSession
        // thread, the scan from a global queue. `fallback: pid` keeps the owner side non-nil.
        let recordOwner = { (owner: Int32?, trusted: Bool) in
            DispatchQueue.main.async {
                answers.recordOwner(owner, trusted: trusted)
                settle(false)
            }
        }
        resolveListener(on: port, fallback: pid) { owner, trusted in
            recordOwner(owner, trusted)
        }
        probeAdoptionHealth(url, pid: pid, port: port, attempt: 1) { healthy in
            DispatchQueue.main.async { [weak self] in
                answers.recordHealth(healthy)
                guard !healthy, let self, settled, self.adoptedPid != nil,
                      self.restartToken == token
                else { return }
                self.adoptedServiceExited()
            }
        }
        // Only the port-owner scan can still hold a launch back; the probe no longer can, so this
        // deadline now covers exactly one wait — a scan that never answers.
        adoptionTimer = Timer.scheduledTimer(
            withTimeInterval: Self.adoptionDeadline,
            repeats: false
        ) { _ in
            settle(true)
        }
    }

    /// Probes an adopted service a few times before declaring it dead.
    ///
    /// A service kept alive across launches is often still busy with the previous session's
    /// first-screen requests; one slow answer is not death. Every attempt asks the real tokenized
    /// URL, and a genuine failure is handed back so the caller can relaunch.
    private func probeAdoptionHealth(
        _ url: URL,
        pid: Int32,
        port: Int,
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        checkHealth(url, timeout: Self.adoptionHealthTimeout) { [weak self] healthy in
            guard let self else {
                completion(healthy)
                return
            }
            // A first miss is only worth retrying while the service could still be there. If the
            // process is gone and nothing listens, answer at once instead of burning two more
            // timeouts on a server that cannot reply.
            let serviceMightBeBusy = kill(pid, 0) == 0 || PortProbe.isInUse(port)
            if healthy || attempt >= Self.adoptionHealthAttempts || !serviceMightBeBusy {
                completion(healthy)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.adoptionRetryDelay) {
                self.probeAdoptionHealth(
                    url,
                    pid: pid,
                    port: port,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
        }
    }

    /// Publishes the reachable URL in both records, preserving the token's original issue time.
    private func publishEndpoint(url: URL, pid: Int32) {
        Self.recordQueue.async {
            let startedAt = ProcessIdentity.startTime(of: pid)
            ServiceSessionStore.save(
                ServiceSession(
                    pid: pid,
                    url: url.absoluteString,
                    startedAt: Date(),
                    processStartedAt: startedAt
                )
            )
            let existing = ServiceEndpointStore.load()
            let issuedAt = existing?.url == url.absoluteString ? (existing?.issuedAt ?? Date()) : Date()
            ServiceEndpointStore.save(
                ServiceEndpoint(
                    pid: pid,
                    url: url.absoluteString,
                    processStartedAt: startedAt,
                    issuedAt: issuedAt
                )
            )
        }
    }

    // MARK: - Spawning

    /// Chooses the configured port, reclaiming it first when a leftover service still holds it.
    ///
    /// The window origin is what keys `localStorage`, so falling back to an ephemeral port hands
    /// every plugin an empty store. A `dsh web` left behind by an earlier launch is therefore asked
    /// to exit instead; only a foreign owner justifies the drift, and then it is reported.
    /// Reuse was tried in the `.reuse` stage before this one; reaching here means no adoption is in
    /// flight, so reclaiming the port is safe.
    private func launchOnAvailablePort() {
        let preferredPort = preferences.port
        guard preferredPort > 0 else {
            launch(port: 0)
            return
        }
        guard PortProbe.isInUse(preferredPort) else {
            launch(port: preferredPort)
            return
        }
        state = .starting(preferences.copy.service.freeingPort(preferredPort))
        // The reclaim runs before any child exists, so nothing else would notice a hang here.
        armDeadline(seconds: Self.startupDeadline)
        // The reclaim can take seconds. A restart during it must win, otherwise this call's
        // completion launches a *second* child while the restart's own launch is still pending —
        // `process` keeps only the newer one and the older child runs on untracked, holding the port.
        restartToken += 1
        let token = restartToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = PortOwner.reclaim(preferredPort)
            DispatchQueue.main.async {
                guard let self, self.restartToken == token, self.state.isStarting else { return }
                switch outcome {
                case .free:
                    self.launch(port: preferredPort)
                case .reclaimed(let pid):
                    ServiceLogTail.note(
                        "reclaimed port \(preferredPort) from a leftover service (pid \(pid))"
                    )
                    self.launch(port: preferredPort)
                case .foreign(let owner):
                    ServiceLogTail.note(
                        "port \(preferredPort) is held by \(owner); falling back to a free port"
                    )
                    self.launch(
                        port: 0,
                        notice: self.preferences.copy.service.portHeld(by: owner, port: preferredPort)
                    )
                }
            }
        }
    }

    /// Runs `dsh web` through the login shell so PATH and profile environment match a terminal.
    /// - Parameters:
    ///   - port: the port to listen on; `0` lets the kernel pick one.
    ///   - notice: an extra sentence shown next to the progress line, e.g. why the port changed.
    private func launch(port: Int, notice: String? = nil) {
        // Last line of defence for the launch race: every caller above only *believes* no child
        // exists. Overwriting `process` here is what orphaned a running service — the old child's
        // pid was lost, `shutdown` never saw it, and the port stayed taken for the next launch.
        guard process == nil else { return }
        isStopping = false
        accessURL = nil
        // The old token dies with the old service; the new banner publishes a fresh one.
        Self.forgetServiceRecord()
        logTail.reset()
        state = .starting(progressMessage(port: port, notice: notice))

        let configuredCommand = ServiceCommand.nonEmpty(preferences.command, fallback: "dsh")
        guard let executable = ServiceCommand.resolve(configuredCommand) else {
            state = .failed(preferences.copy.service.commandMissing(configuredCommand))
            return
        }
        // The service writes its own log: a kept-alive process keeps logging after Orca quits,
        // instead of losing every line into a pipe whose reader just went away. The shell only
        // tails that file for the startup banner and the crash tail.
        guard let log = logTail.open() else {
            state = .failed(preferences.copy.service.launchFailed(executable))
            return
        }
        let profile = ServiceCommand.nonEmpty(preferences.profile, fallback: "web")
        let script = ServiceCommand.script(executable: executable, profile: profile, port: port)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-lc", script]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let searchPaths = Self.searchPath
        environment["PATH"] = searchPaths + ":" + (environment["PATH"] ?? "")
        // Resolve symlinks in the Harness home before the backend boots. dsh's
        // verifyDesktopPath compares a symlink-preserving path against a realpathed
        // one, so any path under a symlinked ~/.dsh fails the check and "Show in
        // Finder" never opens. Pointing DSH_HOME at the real path makes every path
        // the backend computes round-trip cleanly. Override only when the resolved
        // spelling differs, so setups without a symlink keep their default home.
        let dshHomeInput: String
        if let existing = environment["DSH_HOME"], !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dshHomeInput = existing
        } else {
            dshHomeInput = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".dsh")
        }
        let resolvedDshHome = URL(fileURLWithPath: dshHomeInput).resolvingSymlinksInPath().path
        if resolvedDshHome != dshHomeInput {
            environment["DSH_HOME"] = resolvedDshHome
        }
        child.environment = environment
        child.standardOutput = log
        child.standardError = log
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.processDidExit(finished) }
        }

        do {
            try child.run()
        } catch {
            logTail.close()
            state = .failed(preferences.copy.service.launchFailed(executable))
            return
        }

        process = child
        armDeadline(seconds: Self.startupDeadline)
    }

    /// Terminates the child without changing the visible state.
    private func stopChild() {
        cancelTimers()
        let child = detachChild()
        if let child { terminate(child, after: Self.terminationGrace) }
        Self.forgetServiceRecord()
        logTail.close()
    }

    private func processDidExit(_ child: Process) {
        guard process === child else { return }
        detachChild()
        cancelTimers()
        logTail.close()

        guard !isStopping else { return }

        // Retry on the configured port, not an ephemeral one: the port is the page origin, and
        // drifting it would hand every plugin an empty localStorage. `launchOnAvailablePort`
        // reclaims the port from the corpse if it is still held.
        if !didRelaunchAfterCrash {
            didRelaunchAfterCrash = true
            ServiceLogTail.note(
                "the local service exited with status \(child.terminationStatus); relaunching once"
            )
            launchOnAvailablePort()
            return
        }

        let status = child.terminationStatus
        let detail = failureDetail()
        state = .failed(detail ?? preferences.copy.service.exited(status: status))
    }

    /// Best-effort explanation from the captured output, with any token redacted.
    private func failureDetail() -> String? {
        let known: [String] = ["command not found", "EADDRINUSE", "Error:", "error:"]
        let lines = logTail.capturedLines()
        guard let line = lines.last(where: { candidate in
            known.contains(where: { candidate.contains($0) })
        }) ?? lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            return nil
        }
        let redacted = line.replacingOccurrences(
            of: #"token=[A-Za-z0-9_\-]+"#,
            with: "token=…",
            options: .regularExpression
        )
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(240))
    }

    // MARK: - Readiness

    /// Publishes the banner's URL and starts polling the freshly bound service.
    private func handleAccessURL(_ url: URL) {
        guard accessURL == nil, let child = process else { return }
        accessURL = url
        state = .starting(preferences.copy.service.loadingWorkspace)
        publishEndpoint(url: url, pid: child.processIdentifier)
        beginReadinessPolling(url)
    }

    private func beginReadinessPolling(_ url: URL) {
        readinessTimer?.invalidate()
        deadlineTimer?.invalidate()
        let startedAt = Date()
        // A probe takes up to two seconds and a restart can start inside that window. The old
        // completion only asked "is there a child?", which the *new* child satisfies — so it reported
        // the previous tokenized URL as ready, the window loaded an origin nothing listens on, and
        // `readinessTimer = nil` detached the new timer from `cancelTimers()`.
        restartToken += 1
        let token = restartToken
        readinessTimer = runLoopTimer(interval: Self.readinessInterval, repeats: true) { [weak self] _ in
            self?.probeReadiness(url, token: token, startedAt: startedAt)
        }
        // One probe fires immediately, then the timer takes over. The banner this URL came from is
        // printed after the server binds, so the answer is usually already true: waiting for the
        // timer's first fire put a whole polling interval on every launch for nothing.
        probeReadiness(url, token: token, startedAt: startedAt)
    }

    /// Sends one readiness probe, answering only inside the generation that armed it.
    /// - Parameters:
    ///   - url: the tokenized URL the banner printed.
    ///   - token: the restart generation this probe belongs to.
    ///   - startedAt: when polling began, for the give-up deadline.
    private func probeReadiness(_ url: URL, token: Int, startedAt: Date) {
        checkHealth(url) { [weak self] healthy in
            DispatchQueue.main.async {
                guard let self, self.restartToken == token, self.process != nil else { return }
                if healthy {
                    self.readinessTimer?.invalidate()
                    self.readinessTimer = nil
                    self.state = .ready(url)
                    return
                }
                guard Date().timeIntervalSince(startedAt) > Self.readinessDeadline else { return }
                self.readinessTimer?.invalidate()
                self.readinessTimer = nil
                self.fail("The local service did not become ready. See the service log for details.")
            }
        }
    }

    private func armDeadline(seconds: TimeInterval) {
        deadlineTimer = runLoopTimer(interval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.state.isStarting else { return }
            self.fail(self.preferences.copy.service.didNotStart(seconds: Int(seconds)))
        }
    }

    private func fail(_ message: String) {
        stopChild()
        accessURL = nil
        state = .failed(message)
    }

    /// Sends one health probe against the tokenized URL; a 2xx/3xx means the service answers.
    /// - Parameter timeout: an adopted service gets a longer window than a freshly bound one.
    private func checkHealth(
        _ url: URL,
        timeout: TimeInterval = ServiceController.healthTimeout,
        completion: @escaping (Bool) -> Void
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            completion((200..<400).contains(http.statusCode))
        }.resume()
    }

    // MARK: - Helpers

    /// The one-line progress shown while the service boots.
    /// - Parameters:
    ///   - port: the port being used; `0` means the kernel picked one.
    ///   - notice: an extra sentence appended when the port had to change.
    /// - Returns: the message carried by the `starting` state.
    private func progressMessage(port: Int, notice: String?) -> String {
        let copy = preferences.copy.service
        let base = port == 0 ? copy.starting : copy.starting(port: port)
        guard let notice else { return base }
        return "\(base) \(notice)"
    }

    /// Schedules a timer in the common run-loop modes.
    ///
    /// A timer on the default mode stops firing while AppKit tracks a menu or a window drag, which
    /// would leave startup progress frozen for exactly as long as the user held the mouse down.
    /// - Parameters:
    ///   - interval: seconds between fires.
    ///   - repeats: whether the timer fires more than once.
    ///   - handler: called with the timer itself, so a one-shot handler can invalidate it.
    /// - Returns: the scheduled timer, already attached to the main run loop.
    private func runLoopTimer(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: handler)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
