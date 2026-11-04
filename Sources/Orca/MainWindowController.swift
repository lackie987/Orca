import AppKit

/// The main Orca window: vibrancy backdrop, web UI, native drag regions and the startup splash.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let service: ServiceController
    private let preferences: Preferences
    private let page: WebPageController
    private let inspector: InspectorController
    private let chrome: WindowChrome
    private let splash = SplashView()
    private var loadedURL: URL?
    /// True once a page has been shown at least once, so the splash knows a live page sits behind it.
    private var hasRevealedPage = false
    /// Vibrancy under everything: the page keeps its own background clear once the wallpaper patch
    /// is active, so translucent surfaces reveal the blurred desktop instead of a flat colour.
    private var backdropEffect: NSVisualEffectView?
    /// Whether the material above is in use; when it is not, the window paints `baseColor` instead.
    private var glassEnabled = true
    /// Last base colour the page published, i.e. the plane the window paints without the glass.
    private var baseColor: NSColor?
    /// True while the window edge is being dragged; the material steps aside for the duration.
    private var resizeGlassSuspended = false
    /// True when the page paints its own full-window backdrop (an opaque wallpaper).
    ///
    /// The material behind it is then never visible, so it is pure cost — a desktop sample and a
    /// blur per frame of content change. The page frosts its own backdrop instead.
    private var pageCoversWindow = false
    /// The page and the startup surface, i.e. everything the developer-tools panel takes space from.
    /// Safety net for a page that never reports it finished; the surface must not outlive it forever.
    private var revealFallback: DispatchWorkItem?
    /// True while the page is being asked whether a close would interrupt work.
    private var closeDecisionPending = false
    /// True for the close this window performs itself, after the guard has been satisfied.
    private var closeAllowed = false

    /// Longest the startup surface waits for a page that is loading but never finishes.
    private static let revealTimeout: TimeInterval = 12

    init(service: ServiceController, preferences: Preferences) {
        self.service = service
        self.preferences = preferences
        let page = WebPageController(preferences: preferences)
        self.page = page
        self.inspector = InspectorController(page: page)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.chrome = WindowChrome(window: window)
        super.init(window: window)
        configure(window)
        buildContent(in: window)

        // The plugin can change the preset through the bridge; apply it whenever it does.
        page.onTitleBarModeChange = { [weak self] mode in
            self?.chrome.apply(mode)
        }

        // `dsh-patch`'s background tab owns the glass switch; the window plane follows it.
        page.onGlassChange = { [weak self] enabled in
            self?.applyGlass(enabled)
        }

        // Apply the persisted preset at launch so the traffic lights are correct from the first frame.
        chrome.apply(preferences.titleBarMode)
        // AppKit lays the titlebar out once the window is on screen; align after that first pass.
        DispatchQueue.main.async { [weak self] in
            self?.chrome.alignTrafficLights()
        }

        // Paint the plane the theme last published — or the one its pack mirrored while Orca was
        // closed — before the service has even started, so the startup surface already belongs to
        // the page's own plane.
        glassEnabled = preferences.glassEnabled
        paintBase(ThemeColor.launchPlane(preferences))

        LaunchTrace.mark("window")
        connect()
    }

    required init?(coder: NSCoder) {
        fatalError("Orca does not support nib loading")
    }

    // MARK: - Presentation

    func present() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        chrome.alignTrafficLights()
    }

    /// Reapplies settings that can change while the window stays open.
    func applyPreferences() {
        page.applyPreferences()
    }

    // MARK: - Menu actions

    @objc func reloadPage(_ sender: Any?) {
        page.reload()
    }

    @objc func reloadFromOrigin(_ sender: Any?) {
        page.reloadFromOrigin()
    }

    @objc func zoomIn(_ sender: Any?) {
        page.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        page.zoomOut()
    }

    @objc func actualSize(_ sender: Any?) {
        page.resetZoom()
    }

    @objc func toggleDevTools(_ sender: Any?) {
        inspector.toggle()
    }

    @objc func selectElementForInspection(_ sender: Any?) {
        inspector.selectElement()
    }

    @objc func showInspectorConsole(_ sender: Any?) {
        inspector.showConsole()
    }

    @objc func openInBrowser(_ sender: Any?) {
        guard let url = accessURLOrBeep() else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyAccessLink(_ sender: Any?) {
        guard let url = accessURLOrBeep() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// Access URL for the menu commands, beeping while the service has not printed one yet.
    private func accessURLOrBeep() -> URL? {
        guard let url = service.accessURL else {
            NSSound.beep()
            return nil
        }
        return url
    }

    @objc func restartService(_ sender: Any?) {
        service.restart()
    }

    @objc func stopService(_ sender: Any?) {
        service.stop()
    }

    @objc func openServiceLog(_ sender: Any?) {
        guard FileManager.default.fileExists(atPath: AppPaths.serviceLog.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(AppPaths.serviceLog)
    }

    // MARK: - Window delegate

    /// Holds a close while the page still has work running.
    ///
    /// This is the reason the close guard never worked in the shell: ⌘W is the menu's key equivalent
    /// and the red button is AppKit's, so the page never sees either, and dismissing a window does
    /// not unload a WKWebView — `beforeunload` is not consulted at all. The decision therefore has to
    /// be made here, by asking the page (which asks the host, so a turn in *another* session counts
    /// too) before the window goes away.
    ///
    /// Returning `false` keeps the window open until that answer arrives; the close is then performed
    /// by `performClose`, which re-enters this method with the answer already accepted.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeAllowed { return true }
        // Nothing is running until the page has been handed the window: the splash cannot be running
        // a session, and holding a close there would trap the user on an error screen.
        guard hasRevealedPage, !closeDecisionPending else { return !closeDecisionPending }
        closeDecisionPending = true
        page.askCloseGuard { [weak self] running, sessions in
            guard let self else { return }
            self.closeDecisionPending = false
            guard running else {
                self.performGuardedClose()
                return
            }
            self.askBeforeInterrupting(sessions: sessions) { proceed in
                if proceed { self.performGuardedClose() }
            }
        }
        return false
    }

    /// Closes the window with the guard already satisfied.
    private func performGuardedClose() {
        closeAllowed = true
        window?.performClose(nil)
        // Reset on the next run loop turn so a cancelled close (a sheet, a veto from somewhere else)
        // does not leave the window permanently closable.
        DispatchQueue.main.async { [weak self] in
            self?.closeAllowed = false
        }
    }

    /// Asks whether quitting (⌘Q, logout) may proceed, for the same reason as {@link windowShouldClose}.
    /// - Parameter completion: called on the main queue with `true` when termination may continue.
    func confirmTermination(_ completion: @escaping (Bool) -> Void) {
        guard hasRevealedPage else {
            completion(true)
            return
        }
        page.askCloseGuard { [weak self] running, sessions in
            guard let self, running else {
                completion(true)
                return
            }
            self.askBeforeInterrupting(sessions: sessions, completion: completion)
        }
    }

    /// The one prompt both close paths use.
    /// - Parameters:
    ///   - sessions: how many sessions are executing, for the wording.
    ///   - completion: `true` when the user chose to go ahead anyway.
    private func askBeforeInterrupting(sessions: Int, completion: @escaping (Bool) -> Void) {
        let copy = preferences.copy
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.alert.sessionsTitle(count: sessions)
        alert.informativeText = copy.alert.sessionsBody(count: sessions)
        alert.addButton(withTitle: copy.alert.closeAnyway)
        alert.addButton(withTitle: copy.common.cancel)
        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // AppKit re-places the standard buttons on every titlebar layout.
        chrome.alignTrafficLights()
    }

    /// Drops the material for the duration of a live resize.
    ///
    /// A `behindWindow` blur is recomputed against the desktop for every frame the window's area
    /// changes, so dragging an edge pays for a full-window filter pass per frame on top of the
    /// page's own relayout. The plane paints the theme base instead — the window is still moving,
    /// so the loss of frost is not what the eye is following — and the material returns when the
    /// drag ends.
    func windowWillStartLiveResize(_ notification: Notification) {
        guard !resizeGlassSuspended else { return }
        resizeGlassSuspended = true
        refreshWindowPlane()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard resizeGlassSuspended else { return }
        resizeGlassSuspended = false
        refreshWindowPlane()
        chrome.alignTrafficLights()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The first key/main pass is when AppKit finally places the standard buttons in some
        // launch paths (notably hover mode, where they start hidden).
        chrome.alignTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        page.applyFullscreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        page.applyFullscreen(false)
        DispatchQueue.main.async { [weak self] in
            self?.chrome.alignTrafficLights()
        }
    }

    // MARK: - Construction

    private func configure(_ window: NSWindow) {
        window.title = "Orca"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        // The page can now be transparent (the wallpaper patch's interface opacity), so the window
        // itself stops painting: what shows through is the vibrancy view built below. With the
        // glass switched off the window paints the theme base instead — see `refreshWindowPlane`.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 560, height: 620)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self

        if !window.setFrameUsingName("OrcaMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("OrcaMainWindow")
    }

    private func buildContent(in window: NSWindow) {
        let container = NSView()
        container.wantsLayer = true
        window.contentView = container

        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        backdropEffect = effect

        // WebKit docks its own inspector inside the web view, so the shell has nothing to lay out
        // for it: the vibrancy, the page and the startup surface just fill the window.
        Layout.fill(effect, page.webView, splash, in: container)
    }

    private func connect() {
        service.onStateChange = { [weak self] state in
            self?.apply(state)
        }
        page.onThemeSource = { [weak self] source in
            self?.applyTheme(source)
        }
        splash.onRetry = { [weak self] in
            self?.service.restart()
        }
        splash.onOpenLog = {
            NSWorkspace.shared.open(AppPaths.serviceLog)
        }
        page.onPaletteBase = { [weak self] hex in
            self?.applySplashBase(hex)
        }
        page.onPagePainted = { [weak self] in
            self?.revealPage()
        }
        page.onPageLoadFailed = { [weak self] error in
            self?.handlePageLoadFailure(error)
        }
        page.onWebProcessLost = { [weak self] in
            self?.handleWebProcessLost()
        }
        // The page decides when its own backdrop is enough: an opaque wallpaper means the material
        // is covered, so the shell stops sampling the desktop and the page keeps the frost.
        page.onPageBackdropChange = { [weak self] covers in
            guard let self, self.pageCoversWindow != covers else { return }
            self.pageCoversWindow = covers
            self.refreshWindowPlane()
        }
        page.onCloseWindow = { [weak self] in
            self?.window?.performClose(nil)
        }
    }

    /// Stores the base colour a theme published and repaints the splash surface with it.
    ///
    /// The icon is only touched in its `theme` follow mode; `none` and `system` keep the page
    /// theme out of the Dock.
    private func applySplashBase(_ hex: String) {
        guard let color = ColorHex.color(hex) else { return }
        let changed = preferences.splashBaseColor != hex
        preferences.splashBaseColor = hex
        paintBase(color)
        if changed, AppIcon.followsTheme(preferences) {
            // A theme can publish its base more than once while it settles, and each change used to
            // compose a 1024px icon and re-encode seven PNG sizes on the main thread. The debounced
            // path coalesces a burst and does the compose off the main thread.
            AppIconInstaller.applyCurrentDebounced(preferences, forApp: Bundle.main.bundlePath)
            // The icon just changed without the page asking: tell the settings row, otherwise its
            // preview keeps the previous plane until it is reopened.
            pushAppIconState()
        }
    }

    /// Hands the current icon state to the page; used after a repaint the page did not ask for.
    func pushAppIconState() {
        page.pushAppIconState()
    }

    /// Hands the theme base to the startup surface and to the vibrancy behind the page.
    ///
    /// The web view draws no background of its own and the page can now be transparent, so the
    /// backdrop is the shell's vibrancy; the base only picks the appearance its material follows,
    /// keeping a light page over a dark system from frosting in the system's tone. The same base is
    /// what the window paints instead when the glass is switched off.
    private func paintBase(_ color: NSColor?) {
        splash.baseColor = color
        let base = color ?? ThemeColor.boot(preferences)
        baseColor = base
        // The backdrop is the vibrancy view now; the base only decides which appearance its
        // material follows, so a light page over a dark system still frosts in the page's tone.
        backdropEffect?.appearance = NSAppearance(named: ColorHex.isDark(base) ? .darkAqua : .aqua)
        refreshWindowPlane()
    }

    /// Switches the native material on or off, and hands the window's own plane over to it.
    ///
    /// On: the window stays clear so the vibrancy view — the blurred desktop — is what a translucent
    /// page reveals. Off: the material is hidden and the window paints the theme base, so the same
    /// translucent page reveals a flat colour owned by the page's theme instead of the desktop.
    private func applyGlass(_ enabled: Bool) {
        glassEnabled = enabled
        refreshWindowPlane()
    }

    /// Paints the window under the page from the current glass switch and base colour.
    ///
    /// `isOpaque` follows the material rather than staying `false`: a non-opaque window is
    /// composited against the desktop, and with the material off that blend buys nothing — the
    /// window draws an opaque theme plane anyway. Milder than it sounds, and it matters most
    /// during a scroll, where the panel is what the compositor is working on every frame.
    ///
    /// A live resize also suspends the material. The blur re-samples the desktop and re-runs the
    /// filter for every frame of the drag, and the exact frosted look is not what the eye is
    /// following while the window edge is being dragged.
    private func refreshWindowPlane() {
        let glass = glassEnabled && !pageCoversWindow && !resizeGlassSuspended
        window?.backgroundColor = glass ? .clear : (baseColor ?? ThemeColor.boot(preferences))
        backdropEffect?.isHidden = !glass
        window?.isOpaque = !glass
    }

    private func apply(_ state: ServiceState) {
        splash.showsPageBehind = hasRevealedPage
        switch state {
        case .idle:
            splash.showStopped()
        case .starting(let message):
            splash.showStarting(message)
        case .ready(let url):
            // The surface stays up until the page has painted, so the hand-over never shows the
            // bare window. A reload is the only case that has to wait for the web view again.
            LaunchTrace.mark("service ready")
            if loadedURL != url {
                loadedURL = url
                LaunchTrace.mark("navigate")
                page.load(url)
                scheduleRevealFallback()
            } else {
                revealPage()
            }
        case .failed(let message):
            splash.showFailure(message)
        }
    }

    /// Re-renders the startup surface in the shell's current language.
    ///
    /// A ready service is left alone: re-applying it would call `revealPage()` again and dissolve a
    /// surface that is already gone. The other states only repaint text the user is looking at.
    func refreshShellCopy() {
        splash.applyCopy()
        if case .ready = service.state { return }
        apply(service.state)
    }

    /// Reports a page that could not load, and keeps the startup surface in front.
    ///
    /// This used to call `revealPage()`: the surface dissolved onto an empty web view, so a revoked
    /// token, a half-booted server and a dead port all looked like the same blank window. The surface
    /// stays, states the reason WebKit gave, and its buttons already offer a retry and the log.
    /// - Parameter error: the failure from the navigation delegate or the HTTP check.
    private func handlePageLoadFailure(_ error: Error) {
        revealFallback?.cancel()
        revealFallback = nil
        hasRevealedPage = false
        let failure = error as NSError
        let reason = failure.localizedDescription.isEmpty
            ? "\((failure.domain)) \(failure.code)"
            : failure.localizedDescription
        splash.showPageFailure(preferences.copy.splash.pageFailedDetail(reason))
    }

    /// Reports a page whose WebContent process kept exiting after the automatic restarts.
    private func handleWebProcessLost() {
        revealFallback?.cancel()
        revealFallback = nil
        hasRevealedPage = false
        splash.showPageFailure(preferences.copy.splash.webProcessLostDetail)
    }

    /// Hands the window over to the page on the page's own paint report.
    ///
    /// The surface deliberately outlives the service becoming ready: the hand-over is an event from
    /// content that has actually been drawn, not a duration to wait out.
    private func revealPage() {
        revealFallback?.cancel()
        revealFallback = nil
        // A restart may have taken the service away again before the report arrived; keep the
        // surface up in that case rather than dissolving onto a page that is already being replaced.
        guard case .ready = service.state else { return }
        hasRevealedPage = true
        LaunchTrace.mark("painted")
        // The page owns the window from here on; the palette bridge may trust its reports outright.
        page.notePageRevealed()
        splash.dismiss()
    }

    /// Reveals the page even if it never reports finishing, so a hung load cannot trap the surface.
    private func scheduleRevealFallback() {
        revealFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.revealPage()
        }
        revealFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTimeout, execute: work)
    }

    private func applyTheme(_ source: String) {
        let normalized = (source == "light" || source == "dark") ? source : "system"
        // Before the page owns the window, a source that contradicts the choice settled in the
        // previous session is the host applying the system scheme for a frame while its saved theme
        // loads. Following it flips the window chrome — and, through the palette bridge, the startup
        // plane — to the wrong scheme, so keep the settled choice until the page is revealed.
        if !page.isRevealed, !preferences.themeSource.isEmpty, normalized != preferences.themeSource {
            return
        }
        preferences.themeSource = normalized
        switch normalized {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            NSApp.appearance = nil
        }
    }
}
