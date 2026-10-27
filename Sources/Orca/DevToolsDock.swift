import Foundation

/// Where the developer-tools panel sits against the window.
///
/// Bottom is the default because it keeps the page's own column layout intact; right is for wide
/// windows where a full-height panel shows more of a console or a long request list.
enum DevToolsDock: String {
    case bottom
    case right

    /// Title of the menu item that switches *to the other* edge.
    var oppositeMenuTitle: String {
        switch self {
        case .bottom:
            return "Dock Developer Tools on the Right"
        case .right:
            return "Dock Developer Tools at the Bottom"
        }
    }

    static func stored(_ raw: String) -> DevToolsDock {
        DevToolsDock(rawValue: raw) ?? .bottom
    }
}
