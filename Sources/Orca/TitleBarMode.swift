import Foundation

/// Window chrome preset driven by the `dsh-orca-titlebar` plugin through the native bridge.
///
/// `lightsOnly` (the default) keeps the real traffic lights visible over the page's desktop title
/// strip; `hidden` makes them invisible with the page full-bleed; `hover` reveals them while the
/// pointer is in the top band. The raw value is persisted under UserDefaults `titleBarMode`.
///
/// `shown` is a reserved slot, not a preset: it stands for "a standard titled window", which this
/// shell deliberately does not draw — the page's own title strip owns that row. It parses and is
/// carried through so the four names stay available (the plugin still reads an older stored
/// `"shown"`), and it renders exactly like `lightsOnly`.
enum TitleBarMode: String {
    case hidden
    case hover
    case lightsOnly
    /// Placeholder for the standard title bar. No layout of its own; see the note above.
    case shown

    /// Parses a bridge string, falling back to the default preset for anything unknown.
    static func parse(_ value: String?) -> TitleBarMode {
        guard let value, let mode = TitleBarMode(rawValue: value) else { return .lightsOnly }
        return mode
    }
}
