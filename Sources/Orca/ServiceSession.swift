import Foundation

/// A service that outlived the previous Orca launch and can be adopted again.
struct ServiceSession: Codable {
    let pid: Int32
    let url: String
    let startedAt: Date
    /// When the recorded process itself started, read from the kernel at write time.
    ///
    /// Optional because records written before this field existed have none. Those are not adopted:
    /// without it a reused pid cannot be told apart from the real service, and adoption is what
    /// grants permission to signal it later. A record that cannot be verified is treated as stale,
    /// which costs one reconnect and nothing else.
    let processStartedAt: Date?
}

/// Reads and writes the private session record used to reconnect to a kept-alive service.
enum ServiceSessionStore {
    static func load() -> ServiceSession? {
        guard let data = try? Data(contentsOf: AppPaths.serviceSession) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ServiceSession.self, from: data)
    }

    static func save(_ session: ServiceSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: AppPaths.serviceSession, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.serviceSession.path
        )
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.serviceSession)
    }

    /// Whether a loaded session still describes the process its pid points at.
    ///
    /// Both facts have to hold: the start time must have been recorded (older records have none) and
    /// the kernel must still report that time for the pid. Anything less means the pid may belong to
    /// someone else, so the caller must not adopt — and, more importantly, must never signal it.
    /// - Parameter session: the record read from disk.
    /// - Returns: `true` only when the pid provably names the recorded process.
    static func matchesLiveProcess(_ session: ServiceSession) -> Bool {
        guard let recorded = session.processStartedAt else { return false }
        return ProcessIdentity.matches(pid: session.pid, recorded: recorded)
    }
}
