import Foundation

/// Loopback TCP probe, used before the service is handed a port.
enum PortProbe {
    /// Whether something already accepts connections on the loopback `port`.
    static func isInUse(_ port: Int) -> Bool {
        guard port > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Calls `onFree` on the main queue once nothing accepts connections on `port`, or once
    /// `timeout` has passed.
    ///
    /// A restart has to have the old listener gone before the new one binds, and how long that takes
    /// is the outgoing process's business. Pausing for a fixed guess is either longer than the wait
    /// really was or shorter than it, and when it is shorter the new server comes up against a port
    /// that is still held and reports `EADDRINUSE`. Watching the socket is the actual condition.
    /// - Parameters:
    ///   - port: the port to watch; `0` means the kernel picks one, so there is nothing to wait for.
    ///   - timeout: the longest wait before answering anyway.
    ///   - onFree: the work to run on the main queue.
    static func notifyWhenFree(port: Int, within timeout: TimeInterval, onFree: @escaping () -> Void) {
        guard port > 0 else {
            DispatchQueue.main.async(execute: onFree)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(timeout)
            // Probe tight at first — a service that is going usually lets go within milliseconds —
            // then widen, so a stuck one is not hammered for the whole timeout.
            var interval: UInt32 = 5_000
            while Date() < deadline, isInUse(port) {
                usleep(interval)
                interval = min(interval * 2, 100_000)
            }
            DispatchQueue.main.async(execute: onFree)
        }
    }
}
