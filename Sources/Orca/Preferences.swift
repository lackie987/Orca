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
        static let devToolsHeight = "devToolsHeight"
        static let devToolsWidth = "devToolsWidth"
        static let devToolsDock = "devToolsDock"
        static let titleBarMode = "titleBarMode"
        static let splashBaseColor = "splashBaseColor"
        static let appIconPreset = "appIconPreset"
        static let appIconFollowsTheme = "appIconFollowsTheme"
        static let appIconResolvedVariant = "appIconResolvedVariant"
        static let appIconTemplateColor = "appIconTemplateColor"
        static let appIconTemplateFollowsTheme = "appIconTemplateFollowsTheme"
        static let customAppIconPath = "customAppIconPath"
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
            Key.devToolsHeight: 320.0,
            Key.devToolsWidth: 420.0,
            Key.devToolsDock: DevToolsDock.bottom.rawValue,
            Key.titleBarMode: TitleBarMode.lightsOnly.rawValue,
            Key.splashBaseColor: "",
            Key.appIconPreset: "orca",
            Key.appIconFollowsTheme: false,
            Key.appIconResolvedVariant: "",
            Key.appIconTemplateColor: "",
            Key.appIconTemplateFollowsTheme: false,
            Key.customAppIconPath: "",
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

    /// Height of the developer-tools panel when it is docked at the bottom.
    var devToolsHeight: Double {
        get { defaults.double(forKey: Key.devToolsHeight) }
        set { defaults.set(newValue, forKey: Key.devToolsHeight) }
    }

    /// Width of the developer-tools panel when it is docked on the right.
    var devToolsWidth: Double {
        get { defaults.double(forKey: Key.devToolsWidth) }
        set { defaults.set(newValue, forKey: Key.devToolsWidth) }
    }

    /// Edge the developer-tools panel is docked to.
    var devToolsDock: String {
        get { defaults.string(forKey: Key.devToolsDock) ?? DevToolsDock.bottom.rawValue }
        set { defaults.set(newValue, forKey: Key.devToolsDock) }
    }

    /// Window chrome preset written by the `dsh-orca-titlebar` plugin; `lightsOnly` (traffic lights
    /// always visible) by default.
    var titleBarMode: String {
        get { defaults.string(forKey: Key.titleBarMode) ?? TitleBarMode.lightsOnly.rawValue }
        set { defaults.set(newValue, forKey: Key.titleBarMode) }
    }

    /// Base colour published by the web theme for the startup surface; empty before the first report.
    var splashBaseColor: String {
        get { defaults.string(forKey: Key.splashBaseColor) ?? "" }
        set { defaults.set(newValue, forKey: Key.splashBaseColor) }
    }

    /// Selected Dock-icon preset; `"orca"` by default, others resolved through `AppIcon`.
    var appIconPreset: String {
        get { defaults.string(forKey: Key.appIconPreset) ?? "orca" }
        set { defaults.set(newValue, forKey: Key.appIconPreset) }
    }

    /// Whether the chosen preset tracks the page theme's light/dark variant.
    var appIconFollowsTheme: Bool {
        get { defaults.bool(forKey: Key.appIconFollowsTheme) }
        set { defaults.set(newValue, forKey: Key.appIconFollowsTheme) }
    }

    /// Last variant the theme resolved for a themed preset, so the preset holds across reloads.
    var appIconResolvedVariant: String {
        get { defaults.string(forKey: Key.appIconResolvedVariant) ?? "" }
        set { defaults.set(newValue, forKey: Key.appIconResolvedVariant) }
    }

    /// Hex colour the `template` preset fills behind the artwork; empty uses the theme colour.
    var appIconTemplateColor: String {
        get { defaults.string(forKey: Key.appIconTemplateColor) ?? "" }
        set { defaults.set(newValue, forKey: Key.appIconTemplateColor) }
    }

    /// Whether the template preset tracks the page theme colour instead of the fixed one above.
    var appIconTemplateFollowsTheme: Bool {
        get { defaults.bool(forKey: Key.appIconTemplateFollowsTheme) }
        set { defaults.set(newValue, forKey: Key.appIconTemplateFollowsTheme) }
    }

    /// Path to a user-supplied custom icon image, empty until one is chosen.
    var customAppIconPath: String {
        get { defaults.string(forKey: Key.customAppIconPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.customAppIconPath) }
    }
}
