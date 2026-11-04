import Foundation

/// Window chrome preset driven by the `dsh-orca-titlebar` plugin through the native bridge.
///
/// `lightsOnly` (the default) keeps the real traffic lights visible over the page's desktop title
/// strip; `hidden` makes them invisible with the page full-bleed; `hover` reveals them while the
/// pointer is in the top band. The raw value is persisted under UserDefaults `titleBarMode`.
///
/// A fourth case, `shown` (back to a standard `.titled` titlebar), was removed on 2026-11-04: the
/// three presets cover every layout the page draws, and nothing ever selected it. A persisted
/// `"shown"` still parses — it lands on the default, which is the layout those users were moved to.
enum TitleBarMode: String {
    case hidden
    case hover
    case lightsOnly

    /// Parses a bridge string, falling back to the default preset for anything unknown.
    static func parse(_ value: String?) -> TitleBarMode {
        guard let value, let mode = TitleBarMode(rawValue: value) else { return .lightsOnly }
        return mode
    }
}
