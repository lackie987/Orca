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

    /// Native-glass switch requested by the web UI through the `__ORCA_GLASS__` bridge.
    var onGlassChange: ((Bool) -> Void)?

    /// Base colour published by a theme through the `__ORCA_PALETTE__` bridge.
    var onPaletteBase: ((String) -> Void)?

    /// Fired when the page reports whether its own backdrop covers the window.
    ///
    /// `true` means an opaque wallpaper is painted over the whole window, so the native material
    /// underneath is never visible and only costs a desktop sample per frame. The page frosts its
    /// own backdrop with `backdrop-filter` in that case, which the compositor does on the GPU.
    var onPageBackdropChange: ((Bool) -> Void)?

    /// Fired once the page has committed its first painted frame.
    ///
    /// This — not a timer — is what releases the startup surface. `didFinish` only reports that the
    /// load ended, which happens before the compositor has a frame of the new document.
    var onPagePainted: (() -> Void)?

    /// Fired when the main frame gives up loading, so the startup surface never waits forever.
    ///
    /// The error travels with it: the surface used to be dismissed on this signal, leaving a blank
    /// window with no reason on screen and nothing in the log, so a revoked token looked exactly
    /// like a service that never finished booting.
    var onPageLoadFailed: ((Error) -> Void)?

    /// Fired when the WebContent process keeps exiting and the automatic restarts are used up.
    var onWebProcessLost: (() -> Void)?

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
        // WebKit suspends the page's WebProcess as soon as its window counts as invisible. The
        // inspector now lives in a window of its own and can cover the main one, and a hidden or
        // minimized Orca is occluded outright; either way the suspended page loses its WebSocket to
        // the harness ("WebSocket is closed due to suspension") and the UI falls back to reconnect
        // retries. The shell is a long-lived session console, so its page stays alive while open.
        configuration.preferences.setValue(false, forKey: "pageVisibilityBasedProcessSuppressionEnabled")
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = DraggableWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        // Clear, not the boot colour: the window's vibrancy sits behind the page, and a transparent
        // page (the wallpaper patch's interface opacity) must reveal it rather than a flat plane.
        webView.underPageBackgroundColor = .clear

        WebPageScripts.install(
            on: userContentController,
            bootBackground: ThemeColor.bootHex(preferences),
            bootFont: ProfileFont.family(profile: preferences.profile),
            disableInputCompletion: preferences.disableInputCompletion
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
        setInputCompletionDisabled(preferences.disableInputCompletion)
        // Always inspectable: WebKit's inspector only opens on demand (F12, ⌘⇧C, the context menu),
        // and leaving it off by default is what made the old "Web Inspector" menu item look broken.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
    }

    // Disabled: `carryStorage(to:then:)` below replaces this shape. It fired the capture and
    // returned, and `load(_:)` then navigated straight away — the snapshot arrived after the old
    // document was already gone, which is exactly why the store was never carried. Kept for a caller
    // that wants the snapshot without navigating (a future "export my settings", say), where this
    // fire-and-forget form is the right one. It was also never called: `stageStorage(for:)` replays
    // `pendingStorage`, and nothing filled it.
    //
    // /// Snapshots the page's `localStorage` so a restart on another port can carry it over.
    // ///
    // /// Called while the old page is still on screen — the one moment its store is reachable, since
    // /// the new origin cannot read it once the URL has changed.
    // func captureLocalStorage() {
    //     WebPageStorage.capture(from: webView) { [weak self] snapshot in
    //         DispatchQueue.main.async { self?.pendingStorage = snapshot }
    //     }
    // }

    /// How long a capture may hold up a navigation before the load happens without it.
    ///
    /// The capture is one `evaluateJavaScript` round trip into the page's process. A page that is
    /// busy or suspended can take a while to answer, and startup must not wait on it indefinitely —
    /// an empty store is recoverable, a window stuck on the splash is not.
    private static let captureTimeout: TimeInterval = 1.5

    /// Carries the current origin's entries into `url`, then runs `next`.
    ///
    /// - Parameters:
    ///   - url: the origin about to be loaded.
    ///   - next: the navigation, run on the main queue once the capture has settled either way.
    private func carryStorage(to url: URL, then next: @escaping () -> Void) {
        guard let current = webView.url,
              let oldPort = current.port,
              let newPort = url.port,
              oldPort == accessURL?.port,
              oldPort != newPort
        else {
            // Same origin, or no page of ours is loaded: the store is either already the one the new
            // document will see, or there is nothing worth carrying.
            next()
            return
        }
        var settled = false
        let settle = {
            DispatchQueue.main.async {
                guard !settled else { return }
                settled = true
                next()
            }
        }
        WebPageStorage.capture(from: webView) { [weak self] snapshot in
            DispatchQueue.main.async { self?.pendingStorage = snapshot }
            settle()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureTimeout, execute: settle)
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
        // A fresh document has not reported a backdrop yet. Carrying the previous document's
        // "covers the window" over would leave the window opaque over a page that is still
        // see-through, so the material is the assumption until the page speaks again.
        onPageBackdropChange?(false)
    }

    /// Marks the hand-over from the startup surface to the page, after which its palette is trusted.
    func notePageRevealed() {
        isRevealed = true
        // The page rendered, so whatever crashed before is no longer crashing.
        contentProcessRestarts = 0
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
    ///
    /// A new URL on a different port is a new origin, and WebKit keys `localStorage` by origin: the
    /// page would come up with an empty store and every plugin would fall back to its initial state.
    /// The old entries are therefore captured *before* the navigation starts — while the old document
    /// is still the one on screen — and replayed into the new origin at `documentStart`.
    func load(_ url: URL) {
        refreshUserScripts()
        carryStorage(to: url) { [weak self] in self?.navigate(to: url) }
    }

    /// Starts the actual navigation, replaying any captured store into the new origin.
    /// - Parameter url: the URL to load.
    private func navigate(to url: URL) {
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
            bootFont: ProfileFont.family(profile: preferences.profile),
            disableInputCompletion: preferences.disableInputCompletion
        )
    }

    /// Applies the native "disable English autocorrect & autocomplete" setting to the loaded page.
    ///
    /// The page script installs at document end and exposes `__ORCA_INPUT_COMPLETION__.set`; this
    /// call flips it live, and a reload re-installs it with the same default. Elements that were
    /// already adjusted get their previous attributes back when the switch is turned off.
    func setInputCompletionDisabled(_ disabled: Bool) {
        let command = "window.__ORCA_INPUT_COMPLETION__ && window.__ORCA_INPUT_COMPLETION__.set(\(disabled ? "true" : "false"));"
        webView.evaluateJavaScript(command, completionHandler: nil)
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

    /// Consecutive WebContent-process restarts since the page last rendered.
    private var contentProcessRestarts = 0

    /// True while the page is being asked whether a close would interrupt running work.
    private var closeGuardInFlight = false

    /// Name of the page-side probe the close guard installs (dsh-patch's close-guard module).
    ///
    /// The state it reports lives on the host — a turn in another session leaves no marker in this
    /// document — and dismissing the window does not unload a WKWebView, so `beforeunload` never runs
    /// for a native close. Asking the page is therefore the only way to know before the window goes.
    private static let closeGuardProbe = "__dshCloseGuard"

    /// Whether closing now would interrupt work, as the page (and through it, the host) reports.
    ///
    /// The answer is taken fresh: the page re-reads the host rather than trusting a cache, because the
    /// case this exists for is exactly the one a cached page-side view cannot see.
    /// - Parameter completion: called on the main queue with `running` and the session count. A
    ///   missing probe, a wedged page or a timeout all answer "not running", so the guard can never
    ///   turn the close button into a no-op.
    func askCloseGuard(_ completion: @escaping (_ running: Bool, _ sessions: Int) -> Void) {
        guard !closeGuardInFlight else {
            completion(false, 0)
            return
        }
        closeGuardInFlight = true
        var answered = false
        let finish: (Bool, Int) -> Void = { [weak self] running, sessions in
            guard !answered else { return }
            answered = true
            self?.closeGuardInFlight = false
            completion(running, sessions)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false, 0) }
        let script = """
        const probe = window.\(Self.closeGuardProbe);
        if (typeof probe !== "function") return null;
        return await probe();
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            DispatchQueue.main.async {
                guard case .success(let value) = result,
                      let payload = value as? [String: Any]
                else {
                    finish(false, 0)
                    return
                }
                let running = payload["running"] as? Bool ?? false
                let sessions = (payload["sessions"] as? NSNumber)?.intValue ?? 0
                finish(running, running ? max(sessions, 1) : 0)
            }
        }
    }

    /// How many times the shell restarts a WebContent process before it stops trying.
    private static let contentProcessRestartLimit = 2

    /// Base delay between those restarts, multiplied by the attempt number.
    private static let contentProcessRestartDelay: TimeInterval = 1

    /// Recovers from the page's WebContent process exiting.
    ///
    /// The delegate used to call `webView.reload()` on the spot: no delay, no limit, and it bypassed
    /// this type — no user scripts, no loading state, no startup surface. A page that deterministically
    /// kills its own process (memory pressure, a malformed document) therefore blinked white forever
    /// with nothing said. Two attempts with a growing gap, then the shell reports it.
    func recoverWebContentProcess() {
        guard contentProcessRestarts < Self.contentProcessRestartLimit else {
            onWebProcessLost?()
            return
        }
        contentProcessRestarts += 1
        let delay = Self.contentProcessRestartDelay * Double(contentProcessRestarts)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reload()
        }
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
