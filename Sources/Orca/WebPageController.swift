import AppKit
import WebKit

/// Owns the web view that shows the DSH UI: its creation, the injected scripts, the settings that
/// can change at runtime, zoom and the full-screen mirror.
///
/// The delegate and bridge work sits beside it by concern — `WebPageNavigation`, `WebPageBridges`,
/// `WebPageDialogs` — and the page side of the bridges in `WebPageScripts`.
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

    /// Asked by the desktop shortcut bridge when a bound command closes the window.
    var onCloseWindow: (() -> Void)?

    /// One event pushed by the developer-tools agent in the page: its channel and its payload.
    var onDevToolsEvent: ((String, Any) -> Void)?

    /// Fired when the main frame starts loading, so the developer tools can drop their page state.
    var onNavigationStarted: (() -> Void)?

    /// Settings the page-side bridges read and write; shared with the bridge extensions.
    let preferences: Preferences

    /// Tokenized URL currently loaded; `nil` until the shell hands one over.
    private(set) var accessURL: URL?

    /// Snapshot of the origin being left, replayed when the next one is served on another port.
    private var pendingStorage: WebPageStorage.Snapshot?

    /// Windows the page opened and has not closed yet.
    ///
    /// WebKit hands the web view over and keeps nothing else, so without this the window would go
    /// away the moment `window.open` returns.
    private var popups: [WebPagePopup] = []

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
        webView.underPageBackgroundColor = ThemeColor.boot(preferences)

        WebPageScripts.install(
            on: userContentController,
            bootBackground: ThemeColor.bootHex(preferences),
            bootFont: ProfileFont.family(profile: preferences.profile)
        )
        installBridges(on: userContentController)

        applyPreferences()
    }

    /// Opens a window for the page's `window.open` and hands WebKit the web view to drive.
    ///
    /// The popup stays alive here until its window closes, which is also what makes `popup.closed`
    /// answer truthfully on the page side.
    func openPopup(with configuration: WKWebViewConfiguration) -> WKWebView {
        let popup = WebPagePopup(configuration: configuration)
        popup.onClose = { [weak self, weak popup] in
            guard let self, let popup else { return }
            popups.removeAll { $0 === popup }
        }
        popups.append(popup)
        popup.show()
        return popup.webView
    }

    /// Applies settings that can change while the window is open.
    func applyPreferences() {
        setZoom(CGFloat(preferences.pageZoom), persist: false)
        if #available(macOS 13.3, *) {
            webView.isInspectable = preferences.developerExtras
        }
    }

    /// Snapshots the page's `localStorage` so a restart on another port can carry it over.
    ///
    /// Called while the old page is still on screen — the one moment its store is reachable, since
    /// the new origin cannot read it once the URL has changed.
    func captureLocalStorage() {
        WebPageStorage.capture(from: webView) { [weak self] snapshot in
            DispatchQueue.main.async { self?.pendingStorage = snapshot }
        }
    }

    /// Loads the tokenized access URL printed by the service.
    func load(_ url: URL) {
        refreshUserScripts()
        stageStorage(for: url)
        accessURL = url
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    /// Re-installs the injected scripts so the boot background matches the current theme.
    ///
    /// The startup background is baked into a `WKUserScript`; without this a page reload (or a
    /// service restart) would paint the colour from the last app launch, not the theme picked since.
    private func refreshUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        WebPageScripts.install(
            on: controller,
            bootBackground: ThemeColor.bootHex(preferences),
            bootFont: ProfileFont.family(profile: preferences.profile)
        )
    }

    /// Replays the pending snapshot when the URL is about to change origin.
    /// - Parameter url: URL the shell is about to load.
    private func stageStorage(for url: URL) {
        guard let snapshot = pendingStorage, let port = url.port, port != snapshot.port else { return }
        webView.configuration.userContentController.addUserScript(
            WebPageStorage.restoreScript(port: port, snapshot: snapshot)
        )
        pendingStorage = nil
    }

    func reload() {
        withCurrentBase {
            self.refreshUserScripts()
            self.webView.reload()
        }
    }

    func reloadFromOrigin() {
        withCurrentBase {
            self.refreshUserScripts()
            self.webView.reloadFromOrigin()
        }
    }

    /// Reads the base the page is painting right now, so a reload's boot frame follows the live
    /// theme instead of a colour stored on an earlier plane.
    private func withCurrentBase(_ body: @escaping () -> Void) {
        let lock = NSLock()
        var finished = false
        func finish() {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            if first { body() }
        }
        let script = """
        (function () {
          try {
            var host = document.body || document.documentElement;
            if (!host) return '';
            var value = getComputedStyle(host).getPropertyValue('--dsw-alias-bg-base').trim();
            if (!value) value = getComputedStyle(document.documentElement).getPropertyValue('--dsw-alias-bg-base').trim();
            if (!value) return '';
            var probe = document.createElement('span');
            probe.style.color = value;
            host.appendChild(probe);
            var resolved = getComputedStyle(probe).color;
            probe.remove();
            return resolved || value;
          } catch (error) {
            return '';
          }
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            if let self, let raw = result as? String, let hex = ColorHex.fromCSS(raw) {
                self.preferences.splashBaseColor = hex
            }
            finish()
        }
        // A hung web process must not turn the Reload command into a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish() }
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
