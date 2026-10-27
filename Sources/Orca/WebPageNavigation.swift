import AppKit
import WebKit

/// Where the page is allowed to go: internal pages stay in the window, everything else is handed to
/// the system browser, and a failed load releases the startup surface.
extension WebPageController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // Internal pages stay in the window, including the frame-less initial load.
        let staysInside = isInternal(url) &&
            (navigationAction.targetFrame != nil || navigationAction.navigationType == .other)
        if staysInside {
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
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onNavigationStarted?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let fullscreen = webView.window?.styleMask.contains(.fullScreen) ?? false
        applyFullscreen(fullscreen)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onPageLoadFailed?()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        onPageLoadFailed?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - Internal URLs

    /// Whether the URL belongs to the local service this window is showing.
    private func isInternal(_ url: URL) -> Bool {
        guard let accessURL else { return false }
        return url.host == accessURL.host && effectivePort(url) == effectivePort(accessURL)
    }

    /// Port the URL is reached on, filling in the scheme default when it is implicit.
    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme == "https" ? 443 : 80)
    }
}
