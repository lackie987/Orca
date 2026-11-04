import Foundation

/// Append-only log for the lines the page reports from its own console.
///
/// Kept separate from the service log so a noisy page cannot push the server output out of view;
/// the file rotates on its own once it grows past 2 MB.
///
/// The handle stays open for the process. Re-opening per line meant a `stat`, a second `stat`, an
/// `open` and an `lseek` before every write, plus a `close` after it — five system calls to append
/// one line, which matters the moment a plugin starts reporting on a hot path. Rotation is decided
/// from the bytes this session wrote instead of by re-statting the file.
enum WebDiagnostics {
    private static let queue = DispatchQueue(label: "com.xu.orca.diagnostics")
    private static let log = AppPaths.logs.appendingPathComponent("web.log")
    private static let rotateAt = 2_000_000

    /// Open handle and the bytes written through it; both belong to `queue`.
    private static var handle: FileHandle?
    private static var written = 0

    /// Appends one browser-side console line, stamped in ISO 8601.
    static func append(_ line: String) {
        queue.async {
            let data = Data("[\(LogFile.stamp())] \(line)\n".utf8)
            if handle == nil {
                handle = LogFile.openForAppending(log, rotatingBeyond: rotateAt)
                written = 0
            }
            guard let handle else { return }
            guard LogFile.append(data, to: handle) else {
                // A failed write means the descriptor is gone (file removed, volume full). Dropping
                // it makes the next line open a fresh one instead of retrying a dead handle forever.
                try? handle.close()
                self.handle = nil
                return
            }
            written += data.count
            if written >= rotateAt {
                try? handle.close()
                self.handle = nil
            }
        }
    }
}
