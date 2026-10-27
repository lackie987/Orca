import Foundation

/// What the developer tools need from the page they inspect: one command in, one answer out.
///
/// Kept as a protocol so the panel side has no opinion about `WebPageController` — it only needs
/// something that can carry a command to the injected agent.
protocol DevToolsPageBridge: AnyObject {
    /// Sends a command to the page-side agent and reports its answer, already JSON-shaped.
    func devToolsCall(_ command: [String: Any], completion: @escaping (Any?) -> Void)
}
