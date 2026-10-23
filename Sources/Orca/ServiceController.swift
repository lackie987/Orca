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
    private let outputQueue = DispatchQueue(label: "com.xu.orca.service-output")
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var logHandle: FileHandle?
    private var outputBuffer = ""
    private var recentLines: [String] = []
    private var readinessTimer: Timer?
    private var deadlineTimer: Timer?
    private var didFallBackToAutomaticPort = false
    private var isStopping = false
    private var adoptedPid: Int32?
    private var didDiscoverAccessURL = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    deinit {
        readinessTimer?.invalidate()
        deadlineTimer?.invalidate()
    }

    /// Starts the service, adopting a recorded one from an earlier launch when it still answers.
    func start() {
        guard process == nil, !state.isStarting else { return }
        if adoptRecordedService() {
            return
        }
        ServiceSessionStore.clear()
        launchOnAvailablePort()
    }

    /// Restarts the service from scratch, discarding the current process.
    ///
    /// The window reports a restart as one continuous progress state: it never passes through the
    /// stopped state, so the splash keeps its spinner instead of offering buttons mid-refresh.
    func restart() {
        teardown()
        state = .starting("Restarting the local service…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.state.isStarting else { return }
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
    func shutdown() {
        guard !preferences.keepServiceRunningAfterQuit || accessURL == nil else { return }
        isStopping = true
        cancelTimers()
        if adoptedPid != nil {
            releaseAdopted()
            ServiceSessionStore.clear()
        }
        guard let child = detachChild() else {
            ServiceSessionStore.clear()
            return
        }
        if child.isRunning {
            child.terminate()
        }
        let deadline = Date().addingTimeInterval(2)
        while child.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        ServiceSessionStore.clear()
    }

    // MARK: - Process bookkeeping

    /// Stops the readiness and deadline timers.
    private func cancelTimers() {
        readinessTimer?.invalidate()
        readinessTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
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
        guard let pid = adoptedPid else { return }
        kill(pid, SIGTERM)
        adoptedPid = nil
    }

    // MARK: - Spawning

    /// Adopts a service started by an earlier launch when its process and access URL are still healthy.
    ///
    /// Reusing the recorded process keeps the window origin stable, so the web UI keeps its
    /// localStorage state, and it also reclaims a server that survived a crash.
    private func adoptRecordedService() -> Bool {
        guard let session = ServiceSessionStore.load(),
              session.pid > 0,
              kill(session.pid, 0) == 0,
              let url = URL(string: session.url)
        else {
            return false
        }
        accessURL = url
        state = .starting("Reconnecting to the local service…")
        checkHealth(url) { [weak self] healthy in
            DispatchQueue.main.async {
                guard let self, self.process == nil else { return }
                if healthy {
                    self.adoptedPid = session.pid
                    self.state = .ready(url)
                } else {
                    self.accessURL = nil
                    ServiceSessionStore.clear()
                    self.launchOnAvailablePort()
                }
            }
        }
        return true
    }

    /// Chooses the configured port, or an ephemeral one when another process already listens there.
    private func launchOnAvailablePort() {
        let preferredPort = preferences.port
        let port = PortProbe.isInUse(preferredPort) ? 0 : preferredPort
        didFallBackToAutomaticPort = port == 0
        launch(port: port)
    }

    /// Runs `dsh web` through the login shell so PATH and profile environment match a terminal.
    private func launch(port: Int) {
        isStopping = false
        accessURL = nil
        outputBuffer = ""
        recentLines.removeAll()
        didDiscoverAccessURL = false
        state = .starting(port == 0 ? "Starting the local service…" : "Starting the local service on port \(port)…")
        openLog()

        let configuredCommand = ServiceCommand.nonEmpty(preferences.command, fallback: "dsh")
        guard let executable = ServiceCommand.resolve(configuredCommand) else {
            closeLog()
            state = .failed("Orca can’t find “\(configuredCommand)”. Set its path in Settings (⌘,).")
            return
        }
        let profile = ServiceCommand.nonEmpty(preferences.profile, fallback: "web")
        let script = ServiceCommand.script(executable: executable, profile: profile, port: port)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/zsh")
        child.arguments = ["-lc", script]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let searchPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
            state = .failed("Orca can’t launch “\(executable)”. Check the command in Settings (⌘,).")
            return
        }

        process = child
        stdoutPipe = pipe
        armDeadline(seconds: 45)
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

        if !didFallBackToAutomaticPort {
            didFallBackToAutomaticPort = true
            launch(port: 0)
            return
        }

        let status = child.terminationStatus
        let detail = failureDetail()
        state = .failed(detail ?? "The local service exited with status \(status).")
    }

    /// Best-effort explanation from the captured output, with any token redacted.
    private func failureDetail() -> String? {
        let known: [String] = ["command not found", "EADDRINUSE", "Error:", "error:"]
        guard let line = recentLines.last(where: { candidate in
            known.contains(where: { candidate.contains($0) })
        }) ?? recentLines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
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
        logHandle?.write(data)
        let text = String(decoding: data, as: UTF8.self)
        outputBuffer += text
        if outputBuffer.count > 200_000 {
            outputBuffer = String(outputBuffer.suffix(100_000))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            recentLines.append(String(line))
        }
        if recentLines.count > 80 {
            recentLines.removeFirst(recentLines.count - 80)
        }
        guard !didDiscoverAccessURL, let url = Self.parseAccessURL(in: outputBuffer) else { return }
        didDiscoverAccessURL = true
        DispatchQueue.main.async { [weak self] in
            self?.handleAccessURL(url)
        }
    }

    private func handleAccessURL(_ url: URL) {
        guard accessURL == nil, let child = process else { return }
        accessURL = url
        state = .starting("Loading the workspace…")
        ServiceSessionStore.save(
            ServiceSession(pid: child.processIdentifier, url: url.absoluteString, startedAt: Date())
        )
        beginReadinessPolling(url)
    }

    private func beginReadinessPolling(_ url: URL) {
        readinessTimer?.invalidate()
        deadlineTimer?.invalidate()
        let startedAt = Date()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.checkHealth(url) { healthy in
                DispatchQueue.main.async {
                    guard self.process != nil else { return }
                    if healthy {
                        timer.invalidate()
                        self.readinessTimer = nil
                        self.state = .ready(url)
                    } else if Date().timeIntervalSince(startedAt) > 25 {
                        timer.invalidate()
                        self.readinessTimer = nil
                        self.fail("The local service did not become ready. See the service log for details.")
                    }
                }
            }
        }
    }

    private func armDeadline(seconds: TimeInterval) {
        deadlineTimer?.invalidate()
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.state.isStarting else { return }
            self.fail("The local service did not start within \(Int(seconds)) seconds.")
        }
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

    private func openLog() {
        logHandle = LogFile.openForAppending(AppPaths.serviceLog, rotatingBeyond: 4_000_000)
        logHandle?.write(Data("\n==== Orca launch \(LogFile.stamp()) ====\n".utf8))
    }

    private func closeLog() {
        outputQueue.async { [weak self] in
            try? self?.logHandle?.close()
            self?.logHandle = nil
        }
    }

    // MARK: - Helpers

    /// Pulls the tokenized access URL out of the server banner (`dsh web: http://…`).
    private static func parseAccessURL(in text: String) -> URL? {
        let pattern = #"dsh web:\s+(http://\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return URL(string: String(text[range]))
    }
}
