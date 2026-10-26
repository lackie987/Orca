import Foundation

/// Ownership of the local service port, resolved before Orca hands that port to `dsh web`.
///
/// WebKit keys `localStorage` by origin, and the origin here is `http://127.0.0.1:<port>` — so
/// every launch that lands on a different port hands the page a brand-new, empty store and every
/// plugin falls back to its initial state. The common cause is a `dsh web` left behind by an
/// earlier launch: it keeps holding the configured port, and the old code reacted by silently
/// retreating to an ephemeral one.
///
/// This type tells those two situations apart. A leftover dsh service is asked to exit so the
/// configured port — and therefore the origin — stays put; anything else is left untouched and
/// reported, because killing a foreign process is never Orca's call.
enum PortOwner {
    /// What became of the port after one reclaim attempt.
    enum Outcome {
        /// Nothing listens on the port; it can be bound as-is.
        case free
        /// A leftover dsh service held it and has exited.
        case reclaimed(pid: Int32)
        /// Another process owns the port and must not be disturbed.
        case foreign(owner: String)
    }

    /// Grace period for a leftover service to exit on `SIGTERM` before it is killed.
    private static let gracefulTimeout: TimeInterval = 3

    /// Grace period after `SIGKILL`, only long enough to observe the socket closing.
    private static let forcedTimeout: TimeInterval = 1

    /// Polling interval while waiting for the port to close.
    private static let pollInterval: UInt32 = 100_000

    /// Resolves who holds `port`, releasing it when the holder is a leftover dsh service.
    /// - Parameter port: the configured listen port; must be greater than zero.
    /// - Returns: whether the port ended up free, reclaimed, or owned by someone else.
    static func reclaim(_ port: Int) -> Outcome {
        guard let pid = listeningPID(port) else { return .free }
        let command = commandLine(pid) ?? ""
        guard isDshService(command) else { return .foreign(owner: describe(pid: pid, command: command)) }
        requestExit(pid: pid, port: port)
        return PortProbe.isInUse(port)
            ? .foreign(owner: describe(pid: pid, command: command))
            : .reclaimed(pid: pid)
    }

    /// The process listening on `port`, or `nil` when the port is free.
    /// - Parameter port: the port to look up.
    /// - Returns: the pid of the first listener found.
    static func listeningPID(_ port: Int) -> Int32? {
        for path in ["/usr/sbin/lsof", "/usr/bin/lsof"] {
            guard let text = output(of: path, arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]) else {
                continue
            }
            if let pid = text.split(whereSeparator: \.isNewline).first.flatMap({ Int32($0) }) {
                return pid
            }
        }
        return nil
    }

    /// The full command line of `pid`, used to recognise a dsh service.
    /// - Parameter pid: the process to inspect.
    /// - Returns: the command line, or `nil` when it could not be read.
    static func commandLine(_ pid: Int32) -> String? {
        for path in ["/bin/ps", "/usr/bin/ps"] {
            if let text = output(of: path, arguments: ["-o", "command=", "-p", String(pid)]) {
                return text
            }
        }
        return nil
    }

    /// Whether `command` belongs to a `dsh web` service rather than an unrelated program.
    ///
    /// Orca starts the service as `dsh --profile <name> --port <port> --no-open`, so a dsh
    /// command line always carries both the binary and one of those launcher flags. A
    /// `dsh web` started outside Orca (no flags at all) is still the same service holding
    /// this profile's port, so it is reclaimable too — otherwise it would be mistaken for
    /// a foreign owner and Orca would silently retreat to an ephemeral port.
    /// - Parameter command: the command line to classify.
    /// - Returns: `true` when the process is a dsh service.
    static func isDshService(_ command: String) -> Bool {
        guard command.contains("dsh") else { return false }
        if command.contains("--profile") || command.contains("--port") { return true }
        return command.split(separator: " ").contains("web")
    }

    /// Asks the leftover service to exit, escalating to `SIGKILL` if it ignores `SIGTERM`.
    /// - Parameters:
    ///   - pid: the process to stop.
    ///   - port: the port it is holding, waited on to confirm the release.
    private static func requestExit(pid: Int32, port: Int) {
        kill(pid, SIGTERM)
        if waitForRelease(of: port, timeout: gracefulTimeout) { return }
        kill(pid, SIGKILL)
        _ = waitForRelease(of: port, timeout: forcedTimeout)
    }

    /// Waits until nothing listens on `port`.
    /// - Parameters:
    ///   - port: the port to watch.
    ///   - timeout: how long to keep polling.
    /// - Returns: `true` when the port was released within the timeout.
    private static func waitForRelease(of port: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !PortProbe.isInUse(port) { return true }
            usleep(pollInterval)
        }
        return !PortProbe.isInUse(port)
    }

    /// A short human-readable label for the process holding the port.
    /// - Parameters:
    ///   - pid: the owning process.
    ///   - command: its command line, trimmed when unreadable.
    /// - Returns: a label fit for one line of UI text.
    private static func describe(pid: Int32, command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "pid \(pid)" }
        let prefix = String(trimmed.prefix(60))
        return "pid \(pid) (\(prefix))"
    }

    /// Runs one command and captures its standard output.
    /// - Parameters:
    ///   - path: absolute path to the executable.
    ///   - arguments: arguments passed verbatim.
    /// - Returns: the decoded output, or `nil` when the tool is missing or fails to launch.
    private static func output(of path: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
