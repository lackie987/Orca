import AppKit
import WebKit

/// Owns the web view that shows the DSH UI: its creation, the injected scripts, the settings that
/// can change at runtime, zoom and the full-screen mirror.
///
/// The delegate and bridge work sits beside it by concern — `WebPageNavigation`, `WebPageBridges`,
/// `WebPageDialogs` — and the page side of the bridges in `WebPageScripts`.
final class WebPageController: NSObject, InspectorPage {
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
        // `isInspectable` only advertises the page to Safari; WebKit builds the *in-app* inspector
        // front end (and adds "Inspect Element" to the context menu) only when developer extras are
        // on. Without this line `_WKInspector.show` returns immediately and nothing appears.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
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
        // Always inspectable: WebKit's inspector only opens on demand (F12, ⌘⇧C, the context menu),
        // and leaving it off by default is what made the old "Web Inspector" menu item look broken.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
    }

    /// Snapshots the page's `localStorage` so a restart on another port can carry it over.
    ///
    /// Called while the old page is still on screen — the one moment its store is reachable, since
    /// the new origin cannot read it once the URL has changed.
    ///
    /// No caller today: `stageStorage(for:)` still replays `pendingStorage`, but nothing fills it,
    /// so a port change hands the page an empty store. Reconnecting this to the restart path is a
    /// behaviour change — the capture is asynchronous, so `load(_:)` would have to wait for it.
    func captureLocalStorage() {
        WebPageStorage.capture(from: webView) { [weak self] snapshot in
            DispatchQueue.main.async { self?.pendingStorage = snapshot }
        }
    }

    /// True once the startup surface has handed the window over to the page.
    ///
    /// A first painted frame is not enough to trust the page's palette: the boot stream can keep
    /// reporting the system scheme while the saved theme settles, and the hand-over can be delayed
    /// by a slow service. Until the page actually owns the window, a report is validated against the
    /// settled theme instead of being accepted outright — otherwise the startup plane flashes the
    /// wrong scheme and the transient is persisted for the next launch.
    private(set) var isRevealed = false

    /// Marks a fresh document; every load path calls this before the web view starts loading.
    func notePageLoading() {
        isRevealed = false
    }

    /// Marks the hand-over from the startup surface to the page, after which its palette is trusted.
    func notePageRevealed() {
        isRevealed = true
    }

    /// Hands a base colour the page is painting to the shell.
    ///
    /// Every path that learns the painted plane — the palette bridge and the reload-time sample —
    /// goes through here, so `MainWindowController.applySplashBase` stays the only writer of the
    /// stored base. That single owner is what lets it tell a real move from a repeat, and therefore
    /// when a theme-following template icon has to be re-derived.
    func applyPaletteBase(_ hex: String) {
        if let onPaletteBase {
            onPaletteBase(hex)
        } else {
            preferences.splashBaseColor = hex
        }
    }

    /// Loads the tokenized access URL printed by the service.
    func load(_ url: URL) {
        refreshUserScripts()
        stageStorage(for: url)
        accessURL = url
        notePageLoading()
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
            self.notePageLoading()
            self.webView.reload()
        }
    }

    func reloadFromOrigin() {
        withCurrentBase {
            self.refreshUserScripts()
            self.notePageLoading()
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
                // Same door as a palette report: one owner stores the plane and re-derives a
                // theme-following icon when the colour really moved.
                self.applyPaletteBase(hex)
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
