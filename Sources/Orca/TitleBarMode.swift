import Foundation

/// Window chrome preset driven by the `dsh-orca-titlebar` plugin through the native bridge.
///
/// `hidden` keeps the traffic lights invisible and the page full-bleed; `hover` reveals them
/// while the pointer is in the top band; `lightsOnly` shows them above a 44px clear strip;
/// `shown` restores the standard titled chrome. The raw value is persisted under UserDefaults
/// `titleBarMode`.
enum TitleBarMode: String, CaseIterable {
    case hidden
    case hover
    case lightsOnly
    case shown

    /// Parses a bridge string, falling back to `hidden` for anything unknown.
    static func parse(_ value: String?) -> TitleBarMode {
        guard let value, let mode = TitleBarMode(rawValue: value) else { return .hidden }
        return mode
    }
}
