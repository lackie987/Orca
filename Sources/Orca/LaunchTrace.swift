import Foundation

/// Stage marks of one launch, written to the page log.
///
/// The window occasionally takes a noticeable moment to show content, and nothing in the logs says
/// which stage owned that moment: service start, navigation, the first commit, or the first painted
/// frame. One line per stage answers that, and five lines per launch cost nothing worth gating.
///
/// Times are measured from process start, so the service's own spawn is included. A reload or a
/// restart service tap appends a second series in the same file; the timestamps tell them apart.
enum LaunchTrace {
    /// Appends `[launch] <what> +<seconds since process start>` to the page log.
    static func mark(_ what: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime
        WebDiagnostics.append(String(format: "[launch] %@ +%.3fs", what, elapsed))
    }
}
