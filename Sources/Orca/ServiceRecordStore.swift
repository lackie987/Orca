// Disk plumbing shared by the two JSON records the service leaves behind. Both contain the local
// auth token, so encoding, permissions and directory creation must not drift between them.

import Foundation

/// Reads and writes the mode-0600 JSON records that describe the running service.
enum ServiceRecordStore {
    /// Decodes `Record` from `url`; a missing, unreadable or stale file answers `nil`.
    static func load<Record: Decodable>(_ type: Record.Type, from url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// Atomically writes `record` to `url`, creating its parent and restricting permissions.
    static func save<Record: Encodable>(_ record: Record, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the record at `url`; a missing file is not an error.
    static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
