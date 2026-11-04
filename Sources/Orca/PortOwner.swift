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

    /// First gap between release probes. A service that is going to go nearly always does within a
    /// few milliseconds, so polling coarsely here is time added to every restart for nothing.
    private static let initialPollInterval: UInt32 = 10_000

    /// Widest gap between release probes, reached by doubling from `initialPollInterval`.
    private static let maximumPollInterval: UInt32 = 200_000

    /// Resolves who holds `port`, releasing it when the holder is a leftover dsh service.
    /// - Parameter port: the configured listen port; must be greater than zero.
    /// - Returns: whether the port ended up free, reclaimed, or owned by someone else.
    static func reclaim(_ port: Int) -> Outcome {
        guard let pid = PortListener.pid(ofListenerOn: port) else {
            // Nothing *visible* owns it. A process belonging to another user is invisible here, so a
            // port that still answers is answered-for rather than reported free: handing it to
            // `dsh web` would then fail with EADDRINUSE and nothing to say which process it was.
            guard PortProbe.isInUse(port) else { return .free }
            return .foreign(owner: "another user’s process")
        }
        let argv = arguments(of: pid) ?? []
        let command = argv.joined(separator: " ")
        guard isDshService(argv) else { return .foreign(owner: describe(pid: pid, command: command)) }
        requestExit(pid: pid, port: port)
        return PortProbe.isInUse(port)
            ? .foreign(owner: describe(pid: pid, command: command))
            : .reclaimed(pid: pid)
    }

    /// The arguments of `pid`'s command line, used to recognise a dsh service.
    /// - Parameter pid: the process to inspect.
    /// - Returns: `argv[]`, or `nil` when it could not be read.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        // Layout after the count: the executable path, NUL padding up to the next word, then argv[].
        var cursor = MemoryLayout<Int32>.size
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        cursor += 1
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        while arguments.count < argc, cursor < size {
            var finish = cursor
            while finish < size, buffer[finish] != 0 { finish += 1 }
            arguments.append(String(decoding: buffer[cursor..<finish].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            cursor = finish + 1
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// The full command line of `pid`, used for the one-line owner label.
    /// - Parameter pid: the process to inspect.
    /// - Returns: the command line, or `nil` when it could not be read.
    static func commandLine(_ pid: Int32) -> String? {
        arguments(of: pid)?.joined(separator: " ")
    }

    /// Interpreters that run a script named by a later argument, so the service binary is not `argv[0]`.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "tsx", "ts-node", "env"]

    /// Whether `arguments` belong to a `dsh web` service rather than an unrelated program.
    ///
    /// This used to run on the joined command line with `contains("dsh")`, which matched any cwd or
    /// path that merely mentions dsh — this very repository lives at `~/Documents/dsh`, so a plain
    /// `node server.js --port 4319` started from there was classified as a service and killed. The
    /// script the process actually runs now decides, and the launcher flags only narrow it further.
    /// - Parameter arguments: `argv[]` of the candidate process.
    /// - Returns: `true` when the process is a dsh service.
    static func isDshService(_ arguments: [String]) -> Bool {
        guard let script = serviceScript(arguments), isDshScript(script) else { return false }
        if arguments.contains("--profile") || arguments.contains("--port") { return true }
        return arguments.contains("web")
    }

    /// The script path a process runs, skipping the interpreter (and `env`) in front of it.
    /// - Parameter arguments: `argv[]` of the candidate process.
    /// - Returns: the script or executable the process was started with.
    private static func serviceScript(_ arguments: [String]) -> String? {
        var index = 0
        // `env node …/bin/dsh` chains two interpreters; bounded so a long argv cannot walk off.
        while index < arguments.count - 1, interpreters.contains(basename(arguments[index])) {
            index += 1
        }
        return index < arguments.count ? arguments[index] : nil
    }

    /// Whether `path` names the dsh entry point, whether it is the `bin/dsh` symlink or its target.
    /// - Parameter path: the script path from a process's argv.
    /// - Returns: `true` when that path is dsh's own launcher.
    private static func isDshScript(_ path: String) -> Bool {
        if basename(path) == "dsh" { return true }
        // A configured command may point at the resolved shim target (`…/@deepseek-ai/dsh/lib/bin.js`)
        // instead of the symlink, so the resolved form is accepted too.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return basename(resolved) == "dsh" || resolved.contains("/@deepseek-ai/dsh/")
    }

    /// The last path component of `path`.
    /// - Parameter path: a path or bare file name.
    /// - Returns: the file name without its directories.
    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
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
        var interval = initialPollInterval
        while Date() < deadline {
            if !PortProbe.isInUse(port) { return true }
            usleep(interval)
            interval = min(interval * 2, maximumPollInterval)
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

    // Disabled when the pid and command-line lookups moved to `PortListener` and `KERN_PROCARGS2`:
    // `listeningPID` and `commandLine` used to shell out to `lsof` and `ps` through this helper, and
    // both are now in-process. Kept for the one case those two cannot cover — a socket the kernel
    // exposes to `lsof` but not to `libproc` — which nothing has needed so far.
    //
    // /// Runs one command and captures its standard output.
    // /// - Parameters:
    // ///   - path: absolute path to the executable.
    // ///   - arguments: arguments passed verbatim.
    // /// - Returns: the decoded output, or `nil` when the tool is missing or fails to launch.
    // private static func output(of path: String, arguments: [String]) -> String? {
    //     guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    //     let process = Process()
    //     process.executableURL = URL(fileURLWithPath: path)
    //     process.arguments = arguments
    //     let pipe = Pipe()
    //     process.standardOutput = pipe
    //     process.standardError = FileHandle.nullDevice
    //     do {
    //         try process.run()
    //     } catch {
    //         return nil
    //     }
    //     let data = pipe.fileHandleForReading.readDataToEndOfFile()
    //     process.waitUntilExit()
    //     return String(decoding: data, as: UTF8.self)
    // }
}
