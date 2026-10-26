import AppKit

/// The colour the shell paints before the page's own theme has loaded.
///
/// The persisted base is normally enough; the fallback only matters on a first launch, where it
/// follows the system appearance so the startup surface is never the window's plain grey.
enum ThemeColor {
    static func boot(_ preferences: Preferences) -> NSColor {
        if let color = ColorHex.color(preferences.splashBaseColor) { return color }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return ColorHex.color(dark ? "#191724" : "#faf4ed") ?? .windowBackgroundColor
    }

    static func bootHex(_ preferences: Preferences) -> String {
        ColorHex.string(boot(preferences)) ?? "#191724"
    }
}
