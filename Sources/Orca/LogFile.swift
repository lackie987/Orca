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
        _ = try? handle.seekToEnd()
        return handle
    }

    /// Appends `data` to `handle`, swallowing whatever the disk answers.
    ///
    /// `FileHandle` inherits an Objective-C `write(_:)` whose failure mode is not an error value but
    /// an *exception*: `NSFileHandleOperationException` when the volume is full or the descriptor has
    /// gone bad. Nothing here installs an exception handler, so that exception reaches `SIGABRT` with
    /// a stack pointing at the logging line rather than at the trouble that caused it. The Swift
    /// `write(contentsOf:)` reports the same conditions as a thrown error, which `try?` can absorb.
    ///
    /// - Returns: whether the bytes landed, so a caller can stop logging rather than keep raising.
    @discardableResult
    static func append(_ data: Data, to handle: FileHandle?) -> Bool {
        guard let handle else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Current time in ISO 8601, the stamp both logs prefix their lines with.
    ///
    /// One formatter for the process. Constructing an `ISO8601DateFormatter` allocates a fresh
    /// formatter graph, and the earlier shape built one per appended line — the expensive half of
    /// writing a log line. The lock is what makes a shared instance safe: the three logs append
    /// from their own queues, so the same formatter is reached from more than one thread.
    static func stamp() -> String {
        stampLock.lock()
        defer { stampLock.unlock() }
        return isoFormatter.string(from: Date())
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let stampLock = NSLock()
}
