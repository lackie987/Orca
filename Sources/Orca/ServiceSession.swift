// The private reconnect record: which pid and tokenized URL the last launch left behind. Its disk
// I/O is shared with the discoverable endpoint through `ServiceRecordStore`.

import Foundation

/// A service that outlived the previous Orca launch and can be adopted again.
struct ServiceSession: Codable {
    let pid: Int32
    let url: String
    let startedAt: Date
    /// When the recorded process itself started, read from the kernel at write time.
    ///
    /// Optional because records written before this field existed have none. Those are not adopted:
    /// without it a reused pid cannot be told apart from the real service, and adoption is what
    /// grants permission to signal it later. A record that cannot be verified is treated as stale,
    /// which costs one reconnect and nothing else.
    let processStartedAt: Date?
}

/// Reads and writes the private session record used to reconnect to a kept-alive service.
enum ServiceSessionStore {
    /// The last recorded session, or `nil` when the file is missing or stale.
    static func load() -> ServiceSession? {
        ServiceRecordStore.load(ServiceSession.self, from: AppPaths.serviceSession)
    }

    /// Atomically publishes `session` with private permissions.
    static func save(_ session: ServiceSession) {
        ServiceRecordStore.save(session, to: AppPaths.serviceSession)
    }

    /// Forgets the private record. Only a stopped or confirmed-dead service should reach this.
    static func clear() {
        ServiceRecordStore.clear(AppPaths.serviceSession)
    }

    // Dead code: adoption now identifies the service by the process that actually owns the port,
    // so a recorded start time is written but no longer compared. Restore this check if adoption
    // ever has to trust a pid again (a portless transport, say) — signalling a reused pid without
    // it can terminate an unrelated process.
    // static func matchesLiveProcess(_ session: ServiceSession) -> Bool {
    //     guard let recorded = session.processStartedAt else { return false }
    //     return ProcessIdentity.matches(pid: session.pid, recorded: recorded)
    // }
}
