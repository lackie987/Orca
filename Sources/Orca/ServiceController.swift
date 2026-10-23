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
    func restart() {
        stop()
        accessURL = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.start()
        }
    }

    /// Stops the service and clears the session record.
    func stop() {
        isStopping = true
        stopChild()
        if let pid = adoptedPid {
            kill(pid, SIGTERM)
            adoptedPid = nil
        }
        ServiceSessionStore.clear()
        accessURL = nil
        state = .idle
    }

    /// Stops the service for application termination unless the user keeps it alive between launches.
    func shutdown() {
        guard !preferences.keepServiceRunningAfterQuit || accessURL == nil else { return }
        isStopping = true
        readinessTimer?.invalidate()
        deadlineTimer?.invalidate()
        if let pid = adoptedPid {
            kill(pid, SIGTERM)
            adoptedPid = nil
            ServiceSessionStore.clear()
        }
        guard let child = process else {
            ServiceSessionStore.clear()
            return
        }
        process = nil
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
        let port = Self.portIsInUse(preferredPort) ? 0 : preferredPort
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

        let configuredCommand = Self.nonEmpty(preferences.command, fallback: "dsh")
        guard let executable = Self.resolveCommand(configuredCommand) else {
            closeLog()
            state = .failed("Orca can’t find “\(configuredCommand)”. Set its path in Settings (⌘,).")
            return
        }
        let profile = Self.nonEmpty(preferences.profile, fallback: "web")
        let script = "exec \(Self.shellQuote(executable)) --profile \(Self.shellQuote(profile)) --port \(port) --no-open"

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
        readinessTimer?.invalidate()
        readinessTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let child = process else { return }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        if child.isRunning {
            child.terminate()
        }
        let pid = child.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        ServiceSessionStore.clear()
        closeLog()
    }

    private func processDidExit(_ child: Process) {
        guard process === child else { return }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        readinessTimer?.invalidate()
        readinessTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
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
        let manager = FileManager.default
        if !manager.fileExists(atPath: AppPaths.serviceLog.path) {
            manager.createFile(atPath: AppPaths.serviceLog.path, contents: nil)
        }
        if let attributes = try? manager.attributesOfItem(atPath: AppPaths.serviceLog.path),
           let size = attributes[.size] as? Int,
           size > 4_000_000 {
            try? manager.removeItem(at: AppPaths.serviceLog)
            manager.createFile(atPath: AppPaths.serviceLog.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: AppPaths.serviceLog)
        logHandle?.seekToEndOfFile()
        let stamp = ISO8601DateFormatter().string(from: Date())
        logHandle?.write(Data("\n==== Orca launch \(stamp) ====\n".utf8))
    }

    private func closeLog() {
        outputQueue.async { [weak self] in
            try? self?.logHandle?.close()
            self?.logHandle = nil
        }
    }

    // MARK: - Helpers

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

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Resolves a configured command name through the search path a GUI launch actually sees.
    ///
    /// Applications launched by LaunchServices inherit launchd's minimal `PATH`, which omits the
    /// npm global prefix; a bare `dsh` therefore has to be looked up in the common install roots.
    private static func resolveCommand(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = [
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        directories.append(contentsOf: environmentPath.split(separator: ":").map(String.init))
        for directory in directories {
            let candidate = "\(directory)/\(trimmed)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Returns true when a TCP listener already accepts connections on the loopback port.
    private static func portIsInUse(_ port: Int) -> Bool {
        guard port > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Wraps one shell word in single quotes, escaping embedded quotes.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
