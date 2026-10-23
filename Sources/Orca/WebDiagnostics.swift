import Foundation

/// Append-only log for the lines the page reports from its own console.
///
/// Kept separate from the service log so a noisy page cannot push the server output out of view;
/// the file rotates on its own once it grows past 2 MB.
enum WebDiagnostics {
    private static let queue = DispatchQueue(label: "com.xu.orca.diagnostics")
    private static let log = AppPaths.logs.appendingPathComponent("web.log")
    private static let rotateAt = 2_000_000

    /// Appends one browser-side console line, stamped in ISO 8601.
    static func append(_ line: String) {
        queue.async {
            guard let handle = LogFile.openForAppending(log, rotatingBeyond: rotateAt) else { return }
            defer { try? handle.close() }
            handle.write(Data("[\(LogFile.stamp())] \(line)\n".utf8))
        }
    }
}
