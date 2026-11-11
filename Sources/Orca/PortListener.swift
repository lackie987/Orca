import Darwin

/// The pid listening on a local TCP port, resolved in-process instead of by running `lsof`.
///
/// `lsof` answers this question correctly, but it costs a fork and a wait on every launch that finds
/// the port busy, and it depends on a tool resting at a path Apple is free to move. `libproc` exposes
/// the same fact directly: enumerate the pids, list each one's descriptors, and keep the descriptors
/// that are TCP sockets sitting in the listen state with this port bound.
enum PortListener {
    /// The pid holding a listening socket on `port`, or `nil` when nobody has it bound.
    ///
    /// Only processes this user may inspect are visible — exactly as under `lsof`. A socket owned by
    /// another user therefore looks unowned, which callers report rather than act on.
    /// - Parameter port: the port to look for, in host byte order.
    /// - Returns: the pid whose listening socket is bound to that port.
    static func pid(ofListenerOn port: Int) -> Int32? {
        guard port > 0, port <= Int(UInt16.max) else { return nil }
        let wanted = Int32(port)
        for pid in allPIDs() where listeningPorts(of: pid).contains(wanted) {
            return pid
        }
        return nil
    }

    /// Every process currently running, in the order `proc_listallpids` returns them.
    private static func allPIDs() -> [Int32] {
        // Start above the usual process count so one call answers most machines; grow until it fits.
        //
        // `proc_listallpids` answers the number of pids it wrote — not bytes, unlike `proc_pidinfo` —
        // and it truncates silently when the buffer is too small. Reading its answer as a byte count
        // kept only the first quarter of the machine's process list, so the port the service actually
        // listens on was almost never in the walk and this lookup quietly returned nil for a port
        // that was serving.
        var capacity = 2048
        while capacity <= 65_536 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let written = Int(proc_listallpids(&buffer, Int32(capacity * MemoryLayout<Int32>.stride)))
            guard written > 0 else { return [] }
            guard written >= capacity else { return Array(buffer.prefix(written)) }
            capacity *= 2
        }
        return []
    }

    /// The TCP ports `pid` currently accepts connections on.
    private static func listeningPorts(of pid: Int32) -> [Int32] {
        guard let descriptors = descriptors(of: pid) else { return [] }
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        var ports: [Int32] = []
        for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(
                pid,
                descriptor.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socket,
                socketSize
            ) == socketSize else {
                continue
            }
            guard socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // The kernel keeps the bound port in network order in the low half of a wider field,
            // the same value `ntohs` would yield.
            let raw = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            ports.append(Int32(raw.bigEndian))
        }
        return ports
    }

    /// Every open descriptor of `pid`, or `nil` when this process may not read them.
    private static func descriptors(of pid: Int32) -> [proc_fdinfo]? {
        let recordSize = MemoryLayout<proc_fdinfo>.stride
        // A typical process answers well inside this; anything wider is retried below.
        var capacity = 128
        while capacity <= 16_384 {
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let wanted = Int32(capacity * recordSize)
            // A size probe answers how many the process *could* list, not how many it writes back,
            // so the count has to come from what this call actually filled.
            let used = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buffer, wanted))
            guard used > 0 else { return nil }
            let count = used / recordSize
            guard count >= capacity else { return Array(buffer.prefix(count)) }
            capacity *= 2
        }
        return nil
    }
}
