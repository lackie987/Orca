import AppKit
import WebKit

/// Hosts the developer-tools UI in its own web view.
///
/// The panel is a web page like the one it inspects — that is how tabs, trees and tables get built
/// without re-implementing them in AppKit — but it runs from the app bundle, in its own content
/// process, and reaches the shell through exactly one named message channel. Nothing it does can
/// touch the page's own storage or scripts.
final class DevToolsFrontend: NSObject {
    let webView: WKWebView

    /// Called for every message the panel posts; the returned value resolves its promise.
    var onMessage: (([String: Any], @escaping (Any?) -> Void) -> Void)?

    /// Payloads posted before the panel finished loading, replayed in order once it has.
    private var pending: [[String: Any]] = []
    private var isLoaded = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // The panel paints its own surface; a white flash between launch and first paint would be
        // the only thing in Orca that does not belong to the theme.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: DevToolsFrontend.channel
        )

        if let index = DevToolsAssets.indexFile {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(DevToolsAssets.missingAssetsHTML, baseURL: nil)
        }
    }

    /// Message channel name the panel posts on; also the name it looks for in the shell.
    static let channel = "devToolsPanel"

    /// Pushes one payload into the panel, queueing it until the document is ready.
    func send(_ payload: [String: Any]) {
        guard isLoaded else {
            pending.append(payload)
            return
        }
        push(payload)
    }

    private func push(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("[Orca] DevTools panel payload could not be encoded")
            return
        }
        webView.callAsyncJavaScript(
            "window.__orcaDevtoolsPanel && window.__orcaDevtoolsPanel.receive(JSON.parse(json))",
            arguments: ["json": json],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }
}

extension DevToolsFrontend: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let payload = message.body as? [String: Any] else {
            replyHandler(nil, "Malformed panel message")
            return
        }
        guard let onMessage else {
            replyHandler(nil, "Orca is shutting down")
            return
        }
        onMessage(payload) { replyHandler($0, nil) }
    }
}

extension DevToolsFrontend: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let queued = pending
        pending.removeAll()
        for payload in queued {
            push(payload)
        }
    }
}
