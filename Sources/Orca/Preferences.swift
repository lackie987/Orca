import Foundation

/// Settings persisted in the standard user defaults domain.
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let port = "servicePort"
        static let profile = "profileName"
        static let command = "dshCommand"
        static let keepServiceRunning = "keepServiceRunningAfterQuit"
        static let developerExtras = "developerExtras"
        static let pageZoom = "pageZoom"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.port: 4319,
            Key.profile: "web",
            Key.command: "dsh",
            Key.keepServiceRunning: false,
            Key.developerExtras: false,
            Key.pageZoom: 1.0,
        ])
    }

    /// Port handed to `dsh web`; `0` lets the kernel pick a free one.
    var port: Int {
        get { defaults.integer(forKey: Key.port) }
        set { defaults.set(newValue, forKey: Key.port) }
    }

    /// dsh profile booted for the window.
    var profile: String {
        get { defaults.string(forKey: Key.profile) ?? "web" }
        set { defaults.set(newValue, forKey: Key.profile) }
    }

    /// Command resolved by the login shell, either a PATH name or an absolute path.
    var command: String {
        get { defaults.string(forKey: Key.command) ?? "dsh" }
        set { defaults.set(newValue, forKey: Key.command) }
    }

    /// Leaves the spawned service alive when Orca quits so the next launch reconnects.
    var keepServiceRunningAfterQuit: Bool {
        get { defaults.bool(forKey: Key.keepServiceRunning) }
        set { defaults.set(newValue, forKey: Key.keepServiceRunning) }
    }

    /// Exposes the WebKit inspector for the embedded page.
    var developerExtras: Bool {
        get { defaults.bool(forKey: Key.developerExtras) }
        set { defaults.set(newValue, forKey: Key.developerExtras) }
    }

    /// Page zoom preserved across launches.
    var pageZoom: Double {
        get { defaults.double(forKey: Key.pageZoom) }
        set { defaults.set(newValue, forKey: Key.pageZoom) }
    }
}
