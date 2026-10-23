import AppKit
import WebKit

/// Owns the web view that shows the DSH UI: its creation, the injected scripts, the settings that
/// can change at runtime, zoom and the full-screen mirror.
///
/// The delegate and bridge work sits beside it by concern — `WebPageNavigation`, `WebPageBridges`,
/// `WebPageDialogs` — and the page-side half of the bridges in `WebPageScripts`.
final class WebPageController: NSObject {
    let webView: WKWebView

    /// Theme source published by the web UI (`system`, `light` or `dark`).
    var onThemeSource: ((String) -> Void)?

    /// Title-bar preset requested by the web UI through the `__ORCA_TITLEBAR__` bridge.
    var onTitleBarModeChange: ((String) -> Void)?

    /// Base colour published by a theme through the `__ORCA_PALETTE__` bridge.
    var onPaletteBase: ((String) -> Void)?

    /// Fired once the page has committed its first painted frame.
    ///
    /// This — not a timer — is what releases the startup surface. `didFinish` only reports that the
    /// load ended, which happens before the compositor has a frame of the new document.
    var onPagePainted: (() -> Void)?

    /// Fired when the main frame gives up loading, so the startup surface never waits forever.
    var onPageLoadFailed: (() -> Void)?

    /// Settings the page-side bridges read and write; shared with the bridge extensions.
    let preferences: Preferences

    /// Tokenized URL currently loaded; `nil` until the shell hands one over.
    private(set) var accessURL: URL?

    init(preferences: Preferences) {
        self.preferences = preferences

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = DraggableWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        WebPageScripts.install(on: userContentController)
        installBridges(on: userContentController)

        applyPreferences()
    }

    /// Applies settings that can change while the window is open.
    func applyPreferences() {
        setZoom(CGFloat(preferences.pageZoom), persist: false)
        if #available(macOS 13.3, *) {
            webView.isInspectable = preferences.developerExtras
        }
    }

    /// Loads the tokenized access URL printed by the service.
    func load(_ url: URL) {
        accessURL = url
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    func reload() {
        webView.reload()
    }

    func reloadFromOrigin() {
        webView.reloadFromOrigin()
    }

    func zoomIn() {
        setZoom(webView.pageZoom * 1.1, persist: true)
    }

    func zoomOut() {
        setZoom(webView.pageZoom / 1.1, persist: true)
    }

    func resetZoom() {
        setZoom(1, persist: true)
    }

    /// Mirrors the native full-screen state onto `<html data-fullscreen>` so the page reclaims the title-bar clearance.
    func applyFullscreen(_ isFullscreen: Bool) {
        let script = isFullscreen
            ? "document.documentElement.dataset.fullscreen = 'true'"
            : "delete document.documentElement.dataset.fullscreen"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func setZoom(_ value: CGFloat, persist: Bool) {
        let clamped = min(max(value, 0.5), 3)
        webView.pageZoom = clamped
        if persist {
            preferences.pageZoom = Double(clamped)
        }
    }
}
