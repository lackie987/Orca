import Foundation

/// File-level plumbing shared by the append-only logs.
enum LogFile {
    /// Opens `url` for appending, rotating it first once it has grown past `limit` bytes.
    ///
    /// Returns nil when the file cannot be opened at all; log writes are best effort and must never
    /// take the caller down with them.
    static func openForAppending(_ url: URL, rotatingBeyond limit: Int) -> FileHandle? {
        let manager = FileManager.default
        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size > limit {
            try? manager.removeItem(at: url)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    /// Current time in ISO 8601, the stamp both logs prefix their lines with.
    static func stamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
