import Foundation

/// Stage marks of one launch, written to the page log.
///
/// The window occasionally takes a noticeable moment to show content, and nothing in the logs said
/// which stage owned that moment: app startup, service start, navigation, the first commit, the
/// first painted frame, or the native tail that runs alongside them. One line per stage answers
/// that, and a handful of lines per launch cost nothing worth gating.
///
/// The clock is the process's own: `begin()` is the first thing `main.swift` does, so every mark
/// reads as "seconds since Orca started", and a stage that happens before the window exists (the
/// icon pass, AppKit setup) is part of the budget instead of being invisible. It used to print
/// `systemUptime`, which is time since the *machine* booted — the deltas were right but nothing in
/// the log could be read as a total, and the app's own startup could not be measured at all.
enum LaunchTrace {
    /// When this process started, as close to `exec` as the shell can observe.
    private static let start = Date()

    /// Starts the clock. Call once, first thing in `main.swift`.
    ///
    /// `start` is a lazy static, so it would otherwise be initialized by the first `mark(_:)` —
    /// which is the window, i.e. after everything this enum exists to measure.
    static func begin() {
        _ = start
    }

    /// Seconds since `begin()`, for the marks this enum writes.
    private static func elapsed() -> TimeInterval {
        Date().timeIntervalSince(start)
    }

    /// Appends `[launch] <what> +<seconds since process start>` to the page log.
    static func mark(_ what: String) {
        WebDiagnostics.append(String(format: "[launch] %@ +%.3fs", what, elapsed()))
    }
}
