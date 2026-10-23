import Foundation

/// The `dsh web` command line the supervisor runs, built for a login shell.
enum ServiceCommand {
    /// Trims a setting, falling back to `fallback` when it is blank.
    static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Resolves a configured command name through the search path a GUI launch actually sees.
    ///
    /// Applications launched by LaunchServices inherit launchd's minimal `PATH`, which omits the
    /// npm global prefix; a bare `dsh` therefore has to be looked up in the common install roots.
    static func resolve(_ configured: String) -> String? {
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

    /// Wraps one shell word in single quotes, escaping embedded quotes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The login-shell line that boots the service: `exec dsh --profile <profile> --port <port>`.
    static func script(executable: String, profile: String, port: Int) -> String {
        "exec \(shellQuote(executable)) --profile \(shellQuote(profile)) --port \(port) --no-open"
    }
}
