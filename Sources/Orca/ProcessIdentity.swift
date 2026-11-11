// Kernel start time for a process id, written into the service records so a reader can tell a
// reused pid from the recorded process. The shell itself no longer compares it during adoption.

import Darwin
import Foundation

/// Identity of a running process, captured at record-write time.
///
/// A pid alone proves nothing: the kernel reuses numbers, so "this pid is alive" can be true of a
/// completely unrelated process. The start time is fixed for a process's whole life and is not
/// reused, which is why it is stored alongside the pid in both service records.
enum ProcessIdentity {
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

    // Dead code: the comparison was the old adoption guard, replaced by checking which process
    // actually owns the listening port. Restore it together with `ServiceSessionStore`'s check if
    // adoption ever has to trust a recorded pid without a port to verify it against.
    // private static let tolerance: TimeInterval = 1
    // static func matches(pid: Int32, recorded: Date) -> Bool {
    //     guard let started = startTime(of: pid) else { return false }
    //     return abs(started.timeIntervalSince(recorded)) <= tolerance
    // }
}
