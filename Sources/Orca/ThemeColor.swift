import AppKit

/// The colour the shell paints before the page's own theme has loaded.
///
/// The persisted base is what the page last published, so it is only wrong by one launch: a variant
/// changed while Orca was closed lives in the page's own storage and never reached us. The theme
/// pack therefore mirrors both planes of the chosen variant into a file, and a launch prefers it.
enum ThemeColor {
    /// The Mac's appearance, independent of `NSApp.appearance` (which the shell pins to the page).
    static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The plane a launch paints before any page exists: the mirrored one, else the last published.
    static func launchPlane(_ preferences: Preferences) -> NSColor? {
        mirroredPlane(preferences) ?? ColorHex.color(preferences.splashBaseColor)
    }

    static func boot(_ preferences: Preferences) -> NSColor {
        if let color = launchPlane(preferences) { return color }
        let dark = systemIsDark
        return ColorHex.color(dark ? "#191724" : "#faf4ed") ?? .windowBackgroundColor
    }

    static func bootHex(_ preferences: Preferences) -> String {
        ColorHex.string(boot(preferences)) ?? "#191724"
    }

    /// The plane the installed theme pack reported from outside the shell, when there is one.
    ///
    /// The file carries both planes because which one applies is decided here: the theme source can
    /// flip with the Mac while the shell is not running.
    private static func mirroredPlane(_ preferences: Preferences) -> NSColor? {
        guard let data = try? Data(contentsOf: AppPaths.themePlanes),
              let planes = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let side = prefersDarkPlane(preferences) ? "dark" : "light"
        return ColorHex.color(planes[side] as? String)
    }

    /// Whether the next launch opens on the dark side, resolved the way the page resolves it.
    private static func prefersDarkPlane(_ preferences: Preferences) -> Bool {
        switch preferences.themeSource {
        case "light": false
        case "dark": true
        default: systemIsDark
        }
    }
}
