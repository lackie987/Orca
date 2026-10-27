import Foundation
import WebKit

/// What the developer tools need from the page they inspect.
///
/// The command channel is the page's; the three members below are the shell's own — cookies and
/// site data live in `WKWebsiteDataStore`, not in the document, so the page could not answer for
/// them even if it wanted to.
protocol DevToolsPageBridge: AnyObject {
    /// Sends a command to the page-side agent and reports its answer, already JSON-shaped.
    func devToolsCall(_ command: [String: Any], completion: @escaping (Any?) -> Void)

    /// The data store behind the page.
    var devToolsDataStore: WKWebsiteDataStore { get }

    /// Origin the page is currently served from.
    var devToolsOrigin: URL? { get }

    /// Reloads the page, used after its site data has been cleared.
    func devToolsReload()
}
