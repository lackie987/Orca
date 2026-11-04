import Foundation

/// Lifecycle of the local `dsh web` process that backs the Orca window.
enum ServiceState: Equatable {
    case idle
    case starting(String)
    case ready(URL)
    case failed(String)

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }
}

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
    /// Serializes everything the child's output touches.
    ///
    /// `logHandle`, `outputBuffer`, `recentLines` and `didDiscoverAccessURL` are written by `consume`
    /// on this queue (it runs from the pipe's `readabilityHandler`, on a thread of its own) and were
    /// also reset straight from `launch` on the main thread. Two threads mutating one `String` and one
    /// `Array` is a data race whose crash surfaces inside `String.append` with a stack that says
    /// nothing about the service. Every touch now goes through this queue.
    private let outputQueue = DispatchQueue(label: "com.xu.orca.service-output")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var logHandle: FileHandle?
    private var outputBuffer = ""
    private var recentLines: [String] = []
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
    /// Consecutive failed probes of the adopted service; one miss is a busy moment, three are death.
    private var adoptedMisses = 0
    private var isStopping = false
    private var adoptedPid: Int32?
    private var didDiscoverAccessURL = false

    /// Longest a launch may stay in `.starting` before the window reports a timeout.
    private static let startupDeadline: TimeInterval = 45
    /// PATH prefix for the login shell: GUI-launched apps do not inherit a terminal PATH.
    private static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    deinit {
        readinessTimer?.invalidate()
        deadlineTimer?.invalidate()
        adoptionTimer?.invalidate()
        adoptionWatchdog?.invalidate()
    }

    /// Starts the service, adopting a recorded one from an earlier launch when it still answers.
    func start() {
        guard process == nil, !state.isStarting else { return }
        didRelaunchAfterCrash = false
        if adoptRecordedService() {
            return
        }
        ServiceSessionStore.clear()
        launchOnAvailablePort()
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
        PortProbe.notifyWhenFree(port: port, within: 5) { [weak self] in
            guard let self, self.restartToken == token, self.process == nil else { return }
            self.launchOnAvailablePort()
        }
    }

    /// Stops the service and clears the session record.
    func stop() {
        teardown()
        state = .idle
    }

    /// Kills the child process and forgets the recorded session without touching the visible state.
    private func teardown() {
        isStopping = true
        stopChild()
        releaseAdopted()
        ServiceSessionStore.clear()
        accessURL = nil
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
            ServiceSessionStore.clear()
        }
        guard let child = detachChild() else {
            ServiceSessionStore.clear()
            completion()
            return
        }
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
            ServiceSessionStore.clear()
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

    /// Detaches the child and its pipe without signalling it, leaving the caller to decide how.
    @discardableResult
    private func detachChild() -> Process? {
        guard let child = process else { return nil }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
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
        guard let pid = adoptedPid else { return }
        kill(pid, SIGTERM)
        adoptedPid = nil
    }

    // MARK: - Adopted service

    /// Watches a service adopted from an earlier launch.
    ///
    /// Only a child this process spawned reports its own exit; an adopted one does not, and that is
    /// the gap that left the page spinning on "reconnecting": the shell kept the window, the window
    /// kept retrying, and nothing ever learned the server was gone. Process liveness and the loopback
    /// port are both checked, because a server can outlive its listener.
    private func watchAdoptedService(pid: Int32, port: Int) {
        stopAdoptionWatchdog()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, adoptedPid == pid else {
                timer.invalidate()
                return
            }
            if kill(pid, 0) == 0, PortProbe.isInUse(port) {
                adoptedMisses = 0
                return
            }
            adoptedMisses += 1
            guard adoptedMisses >= 3 else { return }
            stopAdoptionWatchdog()
            adoptedServiceExited()
        }
        // `.common`, like the readiness timer: with the default mode a lost service went unnoticed
        // for as long as a menu was open or the window was being dragged.
        RunLoop.main.add(timer, forMode: .common)
        adoptionWatchdog = timer
    }

    /// Stops watching the adopted service and forgets how many probes it has missed.
    private func stopAdoptionWatchdog() {
        adoptionWatchdog?.invalidate()
        adoptionWatchdog = nil
        adoptedMisses = 0
    }

    /// Handles a lost adopted service the way a crashed child is handled: relaunch once, then fail.
    ///
    /// The relaunch mints a new token, so the window loads the page again against a live server
    /// instead of leaving the old document retrying a dead one.
    private func adoptedServiceExited() {
        guard !isStopping, adoptedPid != nil else { return }
        adoptedPid = nil
        accessURL = nil
        ServiceSessionStore.clear()
        guard !didRelaunchAfterCrash else {
            state = .failed(preferences.copy.service.previousStopped)
            return
        }
        didRelaunchAfterCrash = true
        note("the adopted local service stopped answering; relaunching once")
        launchOnAvailablePort()
    }

    // MARK: - Spawning

    /// Adopts a service started by an earlier launch when its process and access URL are still healthy.
    ///
    /// Reusing the recorded process keeps the window origin stable, so the web UI keeps its
    /// localStorage state, and it also reclaims a server that survived a crash. The probe has its own
    /// timeout: a recorded URL that answers nothing must not leave the window on the startup
    /// spinner, because no child process exists for the launch deadline to watch.
    private func adoptRecordedService() -> Bool {
        guard let session = ServiceSessionStore.load(),
              session.pid > 0,
              kill(session.pid, 0) == 0,
              // A live pid is not proof: the kernel reuses numbers, and adopting a reused one handed
              // `teardown` a licence to SIGTERM an unrelated process. The recorded start time is the
              // only thing that distinguishes "our service" from "whoever has that number now".
              ServiceSessionStore.matchesLiveProcess(session),
              let url = URL(string: session.url)
        else {
            return false
        }
        accessURL = url
        state = .starting(preferences.copy.service.reconnecting)
        var settled = false
        // The health check outlives a restart decision. Without a generation of its own, its answer
        // arrives after `teardown` has already cleared the adopted service and re-registers it as
        // `.ready` while a fresh child is being launched — two services on one profile.
        restartToken += 1
        let token = restartToken
        let settle = { [weak self] (healthy: Bool) in
            DispatchQueue.main.async {
                guard let self, !settled else { return }
                settled = true
                self.adoptionTimer?.invalidate()
                self.adoptionTimer = nil
                guard self.restartToken == token, self.process == nil else { return }
                if healthy {
                    self.adoptedPid = session.pid
                    self.state = .ready(url)
                    self.watchAdoptedService(pid: session.pid, port: url.port ?? self.preferences.port)
                } else {
                    self.accessURL = nil
                    ServiceSessionStore.clear()
                    self.launchOnAvailablePort()
                }
            }
        }
        checkHealth(url, completion: settle)
        adoptionTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
            settle(false)
        }
        return true
    }

    /// Chooses the configured port, reclaiming it first when a leftover service still holds it.
    ///
    /// The window origin is what keys `localStorage`, so falling back to an ephemeral port hands
    /// every plugin an empty store. A `dsh web` left behind by an earlier launch is therefore asked
    /// to exit instead; only a foreign owner justifies the drift, and then it is reported.
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
                    self.note("reclaimed port \(preferredPort) from a leftover service (pid \(pid))")
                    self.launch(port: preferredPort)
                case .foreign(let owner):
                    self.note("port \(preferredPort) is held by \(owner); falling back to a free port")
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
        resetCapturedOutput()
        state = .starting(progressMessage(port: port, notice: notice))
        openLog()

        let configuredCommand = ServiceCommand.nonEmpty(preferences.command, fallback: "dsh")
        guard let executable = ServiceCommand.resolve(configuredCommand) else {
            closeLog()
            state = .failed(preferences.copy.service.commandMissing(configuredCommand))
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
        child.environment = environment

        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        child.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.processDidExit(finished) }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.outputQueue.async { self?.consume(data) }
        }

        do {
            try child.run()
        } catch {
            closeLog()
            state = .failed(preferences.copy.service.launchFailed(executable))
            return
        }

        process = child
        stdoutPipe = pipe
        armDeadline(seconds: Self.startupDeadline)
    }

    /// Terminates the child without changing the visible state.
    private func stopChild() {
        cancelTimers()
        guard let child = detachChild() else { return }
        terminate(child, after: 2)
        ServiceSessionStore.clear()
        closeLog()
    }

    private func processDidExit(_ child: Process) {
        guard process === child else { return }
        detachChild()
        cancelTimers()
        closeLog()

        guard !isStopping else { return }

        // Retry on the configured port, not an ephemeral one: the port is the page origin, and
        // drifting it would hand every plugin an empty localStorage. `launchOnAvailablePort`
        // reclaims the port from the corpse if it is still held.
        if !didRelaunchAfterCrash {
            didRelaunchAfterCrash = true
            note("the local service exited with status \(child.terminationStatus); relaunching once")
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
        let lines = capturedLines()
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

    private func consume(_ data: Data) {
        LogFile.append(data, to: logHandle)
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            recentLines.append(String(line))
        }
        if recentLines.count > 80 {
            recentLines.removeFirst(recentLines.count - 80)
        }
        // Past the banner, `outputBuffer` exists only to be searched for it. Concatenating every
        // later chunk onto a buffer that grows to 200 KB, then running the pattern over the whole
        // of it, was work done for the entire life of the service rather than for its startup.
        // `recentLines` above is what a crash still reads, so the tail stays useful.
        guard !didDiscoverAccessURL else { return }
        outputBuffer += text
        if outputBuffer.count > 200_000 {
            outputBuffer = String(outputBuffer.suffix(100_000))
        }
        guard let url = Self.parseAccessURL(in: outputBuffer) else { return }
        didDiscoverAccessURL = true
        DispatchQueue.main.async { [weak self] in
            self?.handleAccessURL(url)
        }
    }

    private func handleAccessURL(_ url: URL) {
        guard accessURL == nil, let child = process else { return }
        accessURL = url
        state = .starting(preferences.copy.service.loadingWorkspace)
        ServiceSessionStore.save(
            ServiceSession(
                pid: child.processIdentifier,
                url: url.absoluteString,
                startedAt: Date(),
                processStartedAt: ProcessIdentity.startTime(of: child.processIdentifier)
            )
        )
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
        readinessTimer = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.checkHealth(url) { healthy in
                DispatchQueue.main.async {
                    guard self.restartToken == token, self.process != nil else { return }
                    if healthy {
                        timer.invalidate()
                        if self.readinessTimer === timer { self.readinessTimer = nil }
                        self.state = .ready(url)
                    } else if Date().timeIntervalSince(startedAt) > 25 {
                        timer.invalidate()
                        if self.readinessTimer === timer { self.readinessTimer = nil }
                        self.fail("The local service did not become ready. See the service log for details.")
                    }
                }
            }
        }
        // `.common` so the progress line keeps counting while a menu is open or the window is being
        // dragged; the default mode stops firing during event tracking.
        RunLoop.main.add(readinessTimer!, forMode: .common)
    }

    private func armDeadline(seconds: TimeInterval) {
        deadlineTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.state.isStarting else { return }
            self.fail(self.preferences.copy.service.didNotStart(seconds: Int(seconds)))
        }
        // `.common`: a startup deadline that pauses while the user holds a menu open is not a deadline.
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func fail(_ message: String) {
        stopChild()
        accessURL = nil
        state = .failed(message)
    }

    /// Sends one unauthenticated health probe; the token URL answers with a redirect, then HTML.
    private func checkHealth(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            completion((200..<400).contains(http.statusCode))
        }.resume()
    }

    // MARK: - Log

    /// Opens the service log and records a launch banner, on the queue that owns the handle.
    private func openLog() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            // A previous launch can leave its handle open — `stopChild` returns before closing when
            // there was no child to stop — and reusing it would drop this launch's banner and skip
            // the rotation check.
            if let existing = self.logHandle {
                try? existing.close()
                self.logHandle = nil
            }
            self.logHandle = LogFile.openForAppending(AppPaths.serviceLog, rotatingBeyond: 4_000_000)
            LogFile.append(Data("\n==== Orca launch \(LogFile.stamp()) ====\n".utf8), to: self.logHandle)
        }
    }

    private func closeLog() {
        outputQueue.async { [weak self] in
            try? self?.logHandle?.close()
            self?.logHandle = nil
        }
    }

    // MARK: - Captured output

    /// Clears what the previous child printed, on the queue that owns it.
    private func resetCapturedOutput() {
        outputQueue.async { [weak self] in
            self?.outputBuffer.removeAll(keepingCapacity: true)
            self?.recentLines.removeAll(keepingCapacity: true)
            self?.didDiscoverAccessURL = false
        }
    }

    /// A copy of the last lines captured, read on the queue that owns them.
    private func capturedLines() -> [String] {
        outputQueue.sync { recentLines }
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

    /// Appends one line to the service log before that log's own handle is opened.
    /// - Parameter line: the note to record, already phrased for a reader.
    private func note(_ line: String) {
        let handle = LogFile.openForAppending(AppPaths.serviceLog, rotatingBeyond: 4_000_000)
        LogFile.append(Data("[orca] \(line)\n".utf8), to: handle)
        try? handle?.close()
    }

    /// Pulls the tokenized access URL out of the server banner (`dsh web: http://…`).
    private static func parseAccessURL(in text: String) -> URL? {
        guard let regex = accessURLPattern,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return URL(string: String(text[range]))
    }

    /// Compiled once. Building an `NSRegularExpression` costs more than running it, and this one
    /// ran on every chunk the child printed until the banner appeared.
    private static let accessURLPattern = try? NSRegularExpression(pattern: #"dsh web:\s+(http://\S+)"#)
}
