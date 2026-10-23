import Foundation

/// Filesystem locations the Orca shell owns.
enum AppPaths {
    /// `~/Library/Application Support/Orca`, created on first access.
    static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Orca", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// `~/Library/Logs/Orca`, created on first access.
    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Logs/Orca", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Captured stdout and stderr of the child `dsh web` process.
    static var serviceLog: URL {
        logs.appendingPathComponent("service.log")
    }

    /// Private record that lets a later launch reconnect to a kept-alive service.
    static var serviceSession: URL {
        applicationSupport.appendingPathComponent("session.json")
    }
}
