import Darwin
import Foundation

/// Identity of a running process, used to prove that a pid recorded by an earlier launch still
/// names the service it was written for.
///
/// A pid alone proves nothing: the kernel reuses numbers, so "this pid is alive" can be true of a
/// completely unrelated process. Adopting one on that basis made `teardown` later send `SIGTERM`
/// to whatever had inherited the number — possibly a document the user had unsaved work in. The
/// start time is fixed for a process's whole life and is not reused, so comparing it is what turns
/// "some process with this pid exists" into "this is the process the session recorded".
enum ProcessIdentity {
    /// Tolerance when comparing a recorded start time with the kernel's, in seconds.
    ///
    /// `Date()` and the kernel's timestamp are read at different moments by different clocks, and
    /// the session record is written a moment after the process starts, so an exact match is not
    /// available. A reused pid is always seconds away, not milliseconds.
    private static let tolerance: TimeInterval = 1

    /// The wall-clock instant `pid` started.
    /// - Parameter pid: the process to inspect.
    /// - Returns: the start time, or `nil` when this process may not read it.
    static func startTime(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        guard info.pbi_start_tvsec > 0 else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
        let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds + microseconds)
    }

    /// Whether `pid` is still the process that started at `recorded`.
    /// - Parameters:
    ///   - pid: the process the caller is about to act on.
    ///   - recorded: the start time stored alongside the pid.
    /// - Returns: `true` only when the kernel agrees this is the same process.
    static func matches(pid: Int32, recorded: Date) -> Bool {
        guard let started = startTime(of: pid) else { return false }
        return abs(started.timeIntervalSince(recorded)) <= tolerance
    }
}
