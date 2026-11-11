// The discoverable endpoint record. Unlike `session.json`, which the supervisor may clear when it
// declines to adopt, this answers "which local service is mine and how do I reach it?" for readers
// outside the shell.

import Foundation

/// A stable, discoverable description of the local service Orca left running.
///
/// `session.json` is the supervisor's private reconnect record: a launch that decides not to adopt
/// clears it, which also throws away the only copy of the service's token. This file answers a
/// different question — "which local service is mine, and how do I reach it?" — so it is written
/// alongside the session record and removed only when the service is actually stopped. A terminal
/// that wants the running UI can read the URL here instead of starting a second `dsh web` on the
/// same port and hitting EADDRINUSE.
struct ServiceEndpoint: Codable {
    let pid: Int32
    /// Tokenized access URL printed by `dsh web`. Mode 0600, like the session record.
    let url: String
    /// Kernel start time of `pid`, used to tell a reused pid from the recorded service.
    let processStartedAt: Date?
    /// When this token was first handed out; restarting the service mints a new one.
    let issuedAt: Date
}

/// Reads and writes the discoverable endpoint record under DSH's state directory.
enum ServiceEndpointStore {
    /// `~/.dsh/state/orca-service.json`, inside DSH's own 0700 home.
    private static var location: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/state/orca-service.json", isDirectory: false)
    }

    /// The last recorded endpoint, or `nil` when none exists or it cannot be decoded.
    static func load() -> ServiceEndpoint? {
        ServiceRecordStore.load(ServiceEndpoint.self, from: location)
    }

    /// Atomically publishes `endpoint` with private permissions.
    static func save(_ endpoint: ServiceEndpoint) {
        ServiceRecordStore.save(endpoint, to: location)
    }

    /// Forgets the endpoint. Only a service that is really gone should reach this.
    static func clear() {
        ServiceRecordStore.clear(location)
    }
}
