import AppKit

/// Resolves which icon Orca should show from the saved preset and its follow mode.
///
/// Four presets ship in `Resources/Icons`: `orca` (the initial icon, which never follows) and the
/// themed `dawn` / `main` / `moon` variants. Each icon has three follow modes: `none` keeps the
/// selection exactly as picked, `theme` follows the page's base colour / variant, and `system`
/// follows the Mac's light/dark appearance. `custom` is a picture the user picked. Every built-in
/// source is full-bleed artwork, so it is composed through `IconProcessor` — otherwise it would sit
/// larger than a system icon and show square corners.
enum AppIcon {
    /// How an icon reacts to its surroundings.
    enum FollowMode: String {
        /// The icon as selected: fixed colour, fixed variant, no outside influence.
        case none
        /// Follow the page theme: its base colour for the template, its variant for themed art.
        case theme
        /// Follow the Mac's light/dark appearance, independent of the page theme.
        case system
    }

    /// Preset identifiers, in the order the settings row shows them. The bridge accepts these and
    /// the row asks for a preview of each.
    static let presets = ["orca", "dawn", "main", "moon", "template", "custom"]

    /// The presets that may follow the Mac's appearance.
    static let themed = ["dawn", "main", "moon"]

    /// The saved follow mode, migrating the legacy boolean switches when it has never been set.
    ///
    /// The old template/themed switches both meant "follow" before the tri-state existed; the
    /// behavior they were left on was the system-follow one, so that is the migration target.
    static func followMode(_ preferences: Preferences) -> FollowMode {
        if let mode = FollowMode(rawValue: preferences.appIconFollowMode) { return mode }
        let followed = preferences.appIconPreset == "template"
            ? preferences.appIconTemplateFollowsTheme
            : (themed.contains(preferences.appIconPreset) && preferences.appIconFollowsTheme)
        return followed ? .system : .none
    }

    /// Whether the selected preset has a colour or variant that can follow anything.
    static func canFollow(_ preferences: Preferences) -> Bool {
        preferences.appIconPreset == "template" || themed.contains(preferences.appIconPreset)
    }

    /// The variant actually displayed for the saved preset.
    ///
    /// `none` keeps the chosen variant; `system` uses the Mac's appearance; `theme` uses the
    /// page-theme variant the bridge last reported, falling back to the page base's darkness.
    /// A `dawn` preset has no dark counterpart, so a dark plane falls back to `main`.
    static func resolvedVariant(_ preferences: Preferences) -> String {
        let preset = preferences.appIconPreset
        guard themed.contains(preset) else { return "orca" }
        switch followMode(preferences) {
        case .none:
            return preset
        case .system:
            guard systemIsDark else { return "dawn" }
            return preset == "dawn" ? "main" : preset
        case .theme:
            let reported = preferences.appIconThemeVariant
            if themed.contains(reported) { return reported }
            if let base = ColorHex.color(preferences.splashBaseColor), ColorHex.isDark(base) {
                return preset == "dawn" ? "main" : preset
            }
            return "dawn"
        }
    }

    /// The composed icon to show, or `nil` when no artwork is available and the bundled icon
    /// should stay in place.
    static func current(_ preferences: Preferences) -> NSImage? {
        if preferences.appIconPreset == "custom",
           let saved = NSImage(contentsOf: AppPaths.customAppIcon) {
            // Already composed when it was picked; reuse it verbatim instead of shrinking it again.
            return saved
        }
        if preferences.appIconPreset == "template", let artwork = templateImage {
            return IconProcessor.template(artwork: artwork, background: templateColor(preferences))
        }
        let variant = resolvedVariant(preferences)
        guard let artwork = artwork(variant) else { return nil }
        return IconProcessor.icon(from: artwork)
    }

    /// The transparent character mark the startup surface draws.
    ///
    /// Not the app icon: that one is a card on the app-icon grid, and a card on the startup surface
    /// would put a colour of its own onto the plane the theme published. The mark has no background
    /// at all, so it lands on whatever colour is under it. `nil` when the resource is missing, which
    /// leaves the surface to fall back to the app icon.
    static func startupMark() -> NSImage? {
        markImage
    }

    /// The icon bundled with the app, drawn when the bundle carries no mark.
    static func startupImage() -> NSImage? {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }

    /// Whether the saved icon re-tints itself when the Mac switches between light and dark.
    ///
    /// This is the icon's own mode, not the page's: the shell pins `NSApp.appearance` to the web
    /// theme, so the page can paint light on a dark Mac without touching the Dock icon.
    static func followsSystemAppearance(_ preferences: Preferences) -> Bool {
        canFollow(preferences) && followMode(preferences) == .system
    }

    /// Whether the saved icon re-tints itself when the page theme changes.
    static func followsTheme(_ preferences: Preferences) -> Bool {
        canFollow(preferences) && followMode(preferences) == .theme
    }

    /// The variant used for the settings row's trigger preview: themed presets show the variant
    /// the icon is actually drawn with, everything else shows its own artwork.
    static func displayVariant(_ preferences: Preferences) -> String {
        let preset = preferences.appIconPreset
        return themed.contains(preset) ? resolvedVariant(preferences) : preset
    }

    /// The icon's own light and dark planes, independent of the page theme.
    static let systemLightBackground = "#faf4ed"
    static let systemDarkBackground = "#191724"

    /// The Mac's appearance, independent of `NSApp.appearance`.
    ///
    /// `NSApp.effectiveAppearance` answers what the shell pinned the app to (the page theme), not
    /// what the system is doing. The global defaults keep the real system answer; the dark value is
    /// `"Dark"`, absent in light mode.
    static var systemIsDark: Bool {
        ThemeColor.systemIsDark
    }

    /// Background colour for the template icon.
    ///
    /// `none` keeps the chosen colour, `theme` takes the page's published base, and `system` picks
    /// the icon's own light/dark plane from the Mac. The page theme never leaks into system mode.
    static func templateColor(_ preferences: Preferences) -> NSColor {
        switch followMode(preferences) {
        case .none:
            if let color = ColorHex.color(preferences.appIconTemplateColor) { return color }
            return ColorHex.color(systemDarkBackground) ?? .windowBackgroundColor
        case .theme:
            if let color = ColorHex.color(preferences.splashBaseColor) { return color }
            let hex = systemIsDark ? systemDarkBackground : systemLightBackground
            return ColorHex.color(hex) ?? .windowBackgroundColor
        case .system:
            let hex = systemIsDark ? systemDarkBackground : systemLightBackground
            return ColorHex.color(hex) ?? .windowBackgroundColor
        }
    }

    /// The template colour as `#rrggbb`, for the settings row's colour well.
    static func templateColorHex(_ preferences: Preferences) -> String {
        ColorHex.string(templateColor(preferences)) ?? "#232136"
    }

    /// The template's own fixed colour, independent of the follow mode. The settings row's colour
    /// well edits this; the preview uses `templateColorHex` (the plane currently painted).
    static func storedTemplateColorHex(_ preferences: Preferences) -> String {
        let color = ColorHex.color(preferences.appIconTemplateColor)
            ?? ColorHex.color(systemDarkBackground)
            ?? .windowBackgroundColor
        return ColorHex.string(color) ?? systemDarkBackground
    }

    /// Base64 PNGs of the icons, for the settings row's chips.
    ///
    /// `only` limits the work to one chip — used when the custom picture changes — while `nil`
    /// returns every preview at once for the initial load.
    static func previews(only: String?) -> [String: String] {
        let names = only.map { presets.contains($0) ? [$0] : [] } ?? presets
        var result: [String: String] = [:]
        for name in names {
            if let data = preview(name: name) {
                result[name] = "data:image/png;base64," + data
            }
        }
        return result
    }

    /// One chip's preview, or `nil` when the artwork is missing.
    ///
    /// The template chip shows the character mark on its own, so it reads as the artwork itself
    /// instead of a colour composite. That also makes it static: it no longer changes with the
    /// template colour or the theme, so nothing has to refresh it.
    private static func preview(name: String) -> String? {
        if name == "template" {
            guard let mark = markImage,
                  let png = IconProcessor.pngData(mark, size: 64)
            else { return nil }
            return png.base64EncodedString()
        }
        let image: NSImage?
        switch name {
        case "custom":
            image = NSImage(contentsOf: AppPaths.customAppIcon)
        default:
            image = artwork(name).flatMap { IconProcessor.icon(from: $0) }
        }
        guard let image, let png = IconProcessor.thumbnailPNG(image, size: 64) else { return nil }
        return png.base64EncodedString()
    }

    /// The transparent character mark the startup surface and the template chip draw.
    ///
    /// Decoded once per process: the chip asks for it every time the settings open, and the PNG is
    /// over a megabyte.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "OrcaMark", withExtension: "png", subdirectory: "Icons"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// The SVG template bundled beside the preset icons.
    ///
    /// Decoded once per process: rasterising the document costs around 120 ms, and the template
    /// icon is re-derived on every activation, preset change and theme switch.
    private static let templateImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "OrcaOutline", withExtension: "svg", subdirectory: "Icons"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// Loads a preset's bundled artwork. `orca` and the themed three share the `Orca` prefix.
    private static func artwork(_ variant: String) -> NSImage? {
        let name: String
        switch variant {
        case "dawn": name = "OrcaDawn"
        case "main": name = "OrcaMain"
        case "moon": name = "OrcaMoon"
        default: name = "Orca"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns", subdirectory: "Icons")
        else { return nil }
        return NSImage(contentsOf: url)
    }
}
