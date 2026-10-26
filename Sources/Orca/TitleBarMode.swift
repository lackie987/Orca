import Foundation

/// Window chrome preset driven by the `dsh-orca-titlebar` plugin through the native bridge.
///
/// `lightsOnly` (the default) keeps the real traffic lights visible over the page's desktop title
/// strip; `hidden` makes them invisible with the page full-bleed; `hover` reveals them while the
/// pointer is in the top band; `shown` restores the standard titled chrome. The raw value is
/// persisted under UserDefaults `titleBarMode`.
enum TitleBarMode: String, CaseIterable {
    case hidden
    case hover
    case lightsOnly
    case shown

    /// Parses a bridge string, falling back to the default preset for anything unknown.
    static func parse(_ value: String?) -> TitleBarMode {
        guard let value, let mode = TitleBarMode(rawValue: value) else { return .lightsOnly }
        return mode
    }
}
