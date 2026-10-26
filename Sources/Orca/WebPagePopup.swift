import AppKit
import WebKit

/// A window the page opened for itself: the shell's half of `window.open`.
///
/// DSH signs in by preopening a blank tab during the click and then pointing that tab at the
/// platform's authorization URL a moment later. A shell that hands every popup to the system browser
/// leaves the page with `null`, so the flow degrades to copying the link into a browser by hand —
/// which is what the desktop runtime is not supposed to need. Blank popups therefore become a real
/// window here: a plain web view on the page's own configuration, so it shares the cookie store and
/// the opener relationship, and the page closes it when the sign-in lands.
///
/// The window is deliberately a plain browser surface — it may go anywhere on the web, unlike the app
/// window, which keeps the local service inside and forwards everything else to the system browser.
final class WebPagePopup: NSObject {
    /// Called once when the window goes away, so the owner can drop its reference.
    var onClose: (() -> Void)?

    /// The web view WebKit asked for; the owner hands this back to `window.open`.
    let webView: WKWebView

    private let window: NSWindow
    private var titleObservation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration) {
        // The popup shows a foreign page, so none of the shell's injected bridges belong in it: the
        // configuration carries the app window's user content controller, and dropping it keeps our
        // scripts out of the sign-in flow. The data store is untouched, so cookies are shared.
        configuration.userContentController = WKUserContentController()

        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Orca"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.center()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // A page title is what the window should be called, so the sign-in window reads like the site
        // it is showing rather than a stray "Orca".
        titleObservation = webView.observe(\.title) { [weak self] webView, _ in
            guard let title = webView.title, !title.isEmpty else { return }
            self?.window.title = title
        }
    }

    /// Puts the window on screen, front and focused: the page expects a tab it can navigate.
    func show() {
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Window lifecycle

extension WebPagePopup: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        // Report on the next turn: the owner drops its reference from `onClose`, and freeing the
        // window inside its own close callback would pull it out from under AppKit's teardown.
        DispatchQueue.main.async { [weak self] in
            self?.onClose?()
        }
    }
}

// MARK: - Navigation

extension WebPagePopup: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        // Downloads are the browser's job: nothing in a sign-in window should land on disk here.
        if navigationAction.shouldPerformDownload {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }
}

// MARK: - Page requests

extension WebPagePopup: WKUIDelegate {
    /// A popup opened from a popup closes the chain: it goes to the system browser instead of
    /// stacking windows the user has to hunt for.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// `window.close()` from the page: the sign-in flow calls this the moment it succeeds.
    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        JavaScriptPanels.alert(message).beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        JavaScriptPanels.confirmation(message).beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}
