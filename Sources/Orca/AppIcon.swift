import AppKit

/// Resolves which icon Orca should show from the saved preset and the reported theme variant.
///
/// Four built-in presets ship in `Resources/Icons`: `orca` (the initial icon, which never follows
/// the theme) and the themed `dawn` / `main` / `moon` variants. The themed three either stay on
/// the chosen variant or follow the theme; `custom` is a picture the user picked. Every built-in
/// source is full-bleed artwork, so it is composed through `IconProcessor` — otherwise it would
/// sit larger than a system icon and show square corners.
enum AppIcon {
    /// Preset identifiers, in the order the settings row shows them. The bridge accepts these and
    /// the row asks for a preview of each.
    static let presets = ["orca", "dawn", "main", "moon", "template", "custom"]

    /// The presets that may follow the theme.
    static let themed = ["dawn", "main", "moon"]

    /// The variant actually displayed for the saved preset.
    static func resolvedVariant(_ preferences: Preferences) -> String {
        let preset = preferences.appIconPreset
        guard themed.contains(preset) else { return "orca" }
        guard preferences.appIconFollowsTheme else { return preset }
        let reported = preferences.appIconResolvedVariant
        return themed.contains(reported) ? reported : preset
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

    /// Whether the resolved icon is painted in the theme's base colour.
    ///
    /// Such an icon has to be recomposed whenever the theme switches planes, otherwise it keeps the
    /// previous plane's colour and stops matching the surface it sits on.
    static func followsBaseColor(_ preferences: Preferences) -> Bool {
        preferences.appIconPreset == "template" && preferences.appIconTemplateFollowsTheme
    }

    /// Background colour for the template, following the theme's base plane when asked to.
    static func templateColor(_ preferences: Preferences) -> NSColor {
        if preferences.appIconTemplateFollowsTheme,
           let theme = ColorHex.color(preferences.splashBaseColor) {
            return theme
        }
        if let color = ColorHex.color(preferences.appIconTemplateColor) { return color }
        if let color = ColorHex.color(preferences.splashBaseColor) { return color }
        return NSColor(
            srgbRed: CGFloat(0x23) / 255,
            green: CGFloat(0x21) / 255,
            blue: CGFloat(0x36) / 255,
            alpha: 1
        )
    }

    /// The template colour as `#rrggbb`, for the settings row's colour well.
    static func templateColorHex(_ preferences: Preferences) -> String {
        ColorHex.string(templateColor(preferences)) ?? "#232136"
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
