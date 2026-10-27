import Foundation

/// Settings persisted in the standard user defaults domain.
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let port = "servicePort"
        static let profile = "profileName"
        static let command = "dshCommand"
        static let keepServiceRunning = "keepServiceRunningAfterQuit"
        static let pageZoom = "pageZoom"
        static let titleBarMode = "titleBarMode"
        static let splashBaseColor = "splashBaseColor"
        static let themeSource = "themeSource"
        static let appIconPreset = "appIconPreset"
        static let appIconFollowsTheme = "appIconFollowsTheme"
        static let appIconFollowMode = "appIconFollowMode"
        static let appIconThemeVariant = "appIconThemeVariant"
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
            Key.pageZoom: 1.0,
            Key.titleBarMode: TitleBarMode.lightsOnly.rawValue,
            Key.splashBaseColor: "",
            Key.themeSource: "",
            Key.appIconPreset: "orca",
            Key.appIconFollowsTheme: false,
            Key.appIconFollowMode: "",
            Key.appIconThemeVariant: "",
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

    /// Page zoom preserved across launches.
    var pageZoom: Double {
        get { defaults.double(forKey: Key.pageZoom) }
        set { defaults.set(newValue, forKey: Key.pageZoom) }
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

    /// Last page theme source reported by the theme bridge: `light`, `dark` or `system`.
    ///
    /// Used to reject the system-scheme palette a host can report for a frame before its saved
    /// light/dark choice lands; an empty value falls back to the persisted base's own lightness.
    var themeSource: String {
        get { defaults.string(forKey: Key.themeSource) ?? "" }
        set { defaults.set(newValue, forKey: Key.themeSource) }
    }

    /// Selected Dock-icon preset; `"orca"` by default, others resolved through `AppIcon`.
    var appIconPreset: String {
        get { defaults.string(forKey: Key.appIconPreset) ?? "orca" }
        set { defaults.set(newValue, forKey: Key.appIconPreset) }
    }

    /// Whether the chosen preset tracks the Mac's light/dark appearance.
    ///
    /// Legacy flag: the settings row now writes `appIconFollowMode`. It is still read once to
    /// migrate an existing choice.
    var appIconFollowsTheme: Bool {
        get { defaults.bool(forKey: Key.appIconFollowsTheme) }
        set { defaults.set(newValue, forKey: Key.appIconFollowsTheme) }
    }

    /// Icon follow mode: `none`, `theme` or `system`. Empty before the first choice; `AppIcon`
    /// migrates the legacy boolean switches in that case.
    var appIconFollowMode: String {
        get { defaults.string(forKey: Key.appIconFollowMode) ?? "" }
        set { defaults.set(newValue, forKey: Key.appIconFollowMode) }
    }

    /// Last page-theme variant reported by the icon bridge (`dawn` / `main` / `moon`), used by the
    /// `theme` follow mode.
    var appIconThemeVariant: String {
        get { defaults.string(forKey: Key.appIconThemeVariant) ?? "" }
        set { defaults.set(newValue, forKey: Key.appIconThemeVariant) }
    }

    /// Hex colour the `template` preset fills behind the artwork; empty uses the icon's dark plane.
    var appIconTemplateColor: String {
        get { defaults.string(forKey: Key.appIconTemplateColor) ?? "" }
        set { defaults.set(newValue, forKey: Key.appIconTemplateColor) }
    }

    /// Whether the template preset follows the Mac's light/dark appearance instead of the fixed
    /// colour above.
    ///
    /// Legacy flag: the settings row now writes `appIconFollowMode`; read once for migration.
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
