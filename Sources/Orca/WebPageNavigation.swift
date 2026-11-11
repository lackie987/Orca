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
        // A 4xx/5xx from the local service is a page that will never paint: the token was minted for
        // another process, the route is gone, or the server is half up. Letting the WebView render the
        // bare body hid all of that behind text in the window; reporting it reaches the surface and
        // the log instead.
        if let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode >= 400,
           let url = http.url,
           isInternal(url) {
            decisionHandler(.cancel)
            onPageLoadFailed?(
                NSError(
                    domain: "OrcaPageError",
                    code: http.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "the service answered HTTP \(http.statusCode) for \(url.path.isEmpty ? "/" : url.path)",
                    ]
                )
            )
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        LaunchTrace.mark("committed")
        onPageCommitted?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        LaunchTrace.mark("finished")
        let fullscreen = webView.window?.styleMask.contains(.fullScreen) ?? false
        applyFullscreen(fullscreen)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportLoadFailure(error)
    }

    /// Hands a failed load to the shell, unless the failure is a normal consequence of a decision.
    ///
    /// Both failure callbacks used to drop the error and release the startup surface, so the window
    /// showed an empty page for any reason at all — and an empty page has no diagnostic value. A
    /// navigation the shell cancelled itself (a link handed to the system browser, a load replaced by
    /// a newer one) is not a failure and would otherwise raise the surface on every click.
    /// - Parameter error: the error WebKit reported.
    private func reportLoadFailure(_ error: Error) {
        let failure = error as NSError
        if failure.domain == "WebKitErrorDomain", failure.code == 102 { return }
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return }
        NSLog("[orca] page load failed: %@ %ld %@", failure.domain, failure.code, failure.localizedDescription)
        onPageLoadFailed?(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recovery lives in the controller: it owns the user scripts, the loading state and the
        // startup surface, all of which a bare `reload()` here skipped.
        recoverWebContentProcess()
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
