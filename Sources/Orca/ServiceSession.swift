import Foundation

/// A service that outlived the previous Orca launch and can be adopted again.
struct ServiceSession: Codable {
    let pid: Int32
    let url: String
    let startedAt: Date
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
}
