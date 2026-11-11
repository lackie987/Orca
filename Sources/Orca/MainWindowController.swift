import AppKit

/// The main Orca window: vibrancy backdrop, web UI, native drag regions and the startup splash.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let service: ServiceController
    private let preferences: Preferences
    private let page: WebPageController
    private let inspector: InspectorController
    private let chrome: WindowChrome
    private let splash = SplashView()
    // Retired: the ready path compared this URL to decide whether to load again. It answered "did we
    // ever ask for this URL", not "is that document still on screen" — and two `.ready` states for
    // one URL only ever differ when the document was replaced in between. `hasRevealedPage` together
    // with `page.isRevealed` answers the real question; kept here for reference in case a second
    // window ever needs to know which URL this one was navigated to.
    // private var loadedURL: URL?
    /// True once a page has been shown at least once, so the splash knows a live page sits behind it.
    ///
    /// Not the same as `page.isRevealed`, which answers whether the *current* document has reported
    /// a frame: a reload clears that one and leaves this true, which is what tells the shell the
    /// blank stretch belongs to a reload and needs the quiet cover.
    private var hasRevealedPage = false
    /// True while the quiet cover for a reload's blank document is up.
    private var quietShown = false
    /// True while the splash is showing a state the *service* asked for — starting, stopped, failed.
    ///
    /// A reload and a service restart look identical from the page's side: both commit a new
    /// document. Only the restart already has the full startup surface up, with a reason on it, so
    /// the page must not replace that with the wordless cover.
    private var splashOwnedByService = false
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
    // Retired: the wake / occlusion probe. It asked the page for an animation frame after every
    // long absence and restarted the WebContent process when no frame came back. The question
    // cannot be asked cheaply or safely: a page that is merely busy (a long task on its main
    // thread, a heavy repaint after a wake) answers late and was reloaded for it, which costs
    // 0.9-1.3s and the page's scroll and input state. WebKit already reports the case that matters
    // — `webViewWebContentProcessDidTerminate` — and that is what the cover hangs off now.
    //
    // Kept because a probe is the only way to detect a page whose process is alive but cannot
    // draw; if a reliable signal ever appears, the shape to restore is: throttle (3s), require
    // `NSApp.isActive` and a visible window, and treat a missing answer as "unknown", not "dead".
    // private var occludedSince: Date?
    // private var inactiveSince: Date?
    // private var lastResumeCheck = Date.distantPast
    /// True while the page is being asked whether a close would interrupt work.
    private var closeDecisionPending = false
    /// Retired with the move off `performClose:` — nothing re-enters `windowShouldClose` for a close
    /// the shell performs itself, so the flag no longer has a second pass to allow.
    ///
    /// Kept commented in case a future path hands the close back to AppKit, where the re-entry
    /// (`windowShouldClose` asked once, then again by the close itself) would be needed again.
    // private var closeAllowed = false

    /// Fires once when the service first answers with something other than "starting".
    ///
    /// The launch's native tail (the hotkey surface, the appearance observer, the icon pass) waits
    /// for this: it is native work that has nothing to ask of the page, and running it before the
    /// answer sits between the service and the document that answer is for.
    var onServiceAnswered: (() -> Void)?
    /// Whether {@link onServiceAnswered} has fired. One answer per launch.
    private var didAnnounceService = false

    /// Longest the startup surface waits for a page that is loading but never finishes.
    private static let revealTimeout: TimeInterval = 12

    /// Dissolve of the quiet cover. Shorter than the startup surface's: the page underneath is
    /// already painting by the time it comes off.
    private static let quietFadeOut: TimeInterval = 0.22

    // Retired with the probe: the frame timeout, the absence it measured and the spacing between
    // two probes. All three only existed to keep one question — "can the page still draw?" — from
    // being asked too often or answered too eagerly.
    // private static let resumeProbeTimeout: TimeInterval = 2
    // private static let resumeGrace: TimeInterval = 20
    // private static let resumeCheckSpacing: TimeInterval = 3

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

    // The observer cleanup went with the probe it existed for: nothing here observes a notification
    // any more, and a `deinit` that removes observers none were added to is noise. Restore it
    // alongside any future `addObserver(self, …)`.
    // deinit {
    //     NSWorkspace.shared.notificationCenter.removeObserver(self)
    //     NotificationCenter.default.removeObserver(self)
    // }

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
        guard canReloadPage else { return }
        page.reload()
    }

    @objc func reloadFromOrigin(_ sender: Any?) {
        guard canReloadPage else { return }
        page.reloadFromOrigin()
    }

    /// Whether a manual reload has a URL worth re-fetching.
    ///
    /// Reloading while the service is starting or gone points the web view at a token that is being
    /// replaced, and the failure that follows would overwrite the startup surface's own reason with
    /// a page error. Those states already offer their own retry.
    private var canReloadPage: Bool {
        if case .ready = service.state { return true }
        return false
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

    /// Answers AppKit's own close request — the red light, once the page's title band reveals it.
    ///
    /// The answer is always `false`: {@link requestClose} performs the close once the page has
    /// allowed it, so a veto leaves the window open instead of AppKit closing underneath it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    /// Holds a close while the page still has work running, then closes the window.
    ///
    /// The decision has to be made here: ⌘W is the menu's key equivalent and the red light is
    /// AppKit's, so the page never sees either, and dismissing a window does not unload a WKWebView
    /// — `beforeunload` is not consulted at all. `askCloseGuard` asks the page, which asks the host,
    /// so a turn in *another* session counts too.
    ///
    /// The close itself cannot be `performClose:`: that action simulates a click on the standard
    /// close button, and this window keeps its traffic lights hidden behind the page's own title
    /// band, which leaves that button disabled — the File menu's ⌘W then ran a silent no-op, with
    /// no prompt and no close, exactly as if the shortcut were not wired at all.
    func requestClose() {
        guard !closeDecisionPending else { return }
        // Nothing is running until the page has been handed the window: the splash cannot be running
        // a session, and holding a close there would trap the user on an error screen.
        guard hasRevealedPage else {
            window?.close()
            return
        }
        closeDecisionPending = true
        page.askCloseGuard { [weak self] running, sessions in
            guard let self else { return }
            self.closeDecisionPending = false
            guard running else {
                self.window?.close()
                return
            }
            self.askBeforeInterrupting(sessions: sessions) { proceed in
                if proceed { self.window?.close() }
            }
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

    // Retired: the wake / occlusion / activation probe, and the delegate callback that timed how
    // long the window was out of the compositor's sight. A window buried behind others produces no
    // frames, and what the compositor reclaims in that state is reclaimed without telling the app —
    // but every way of asking afterwards ("give me an animation frame") answers late for a page
    // that is merely busy, and a late answer here means a reload of a page that was fine.
    // `webViewWebContentProcessDidTerminate` reports the case that actually blanks the view.
    // func windowDidChangeOcclusionState(_ notification: Notification) { … }
    // @objc private func systemDidWake() { … }
    // @objc private func applicationWillResignActive() { … }
    // @objc private func applicationDidBecomeActive() { … }

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
            self?.revealPage("page")
        }
        page.onPageCommitted = { [weak self] in
            self?.coverBlankPage()
        }
        // A process that exits leaves the view empty from that instant, and the shell's restart is
        // deliberately delayed — cover now, not when the replacement document commits.
        page.onWebProcessTerminated = { [weak self] in
            self?.coverBlankPage()
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
            // Same guard as the red light and ⌘W: the page asking is not proof that nothing is
            // running, and `performClose:` would have been a no-op on the disabled close button.
            self?.requestClose()
        }
        // The service chain starts in `main.swift`, before AppKit comes up, so a launch that adopts a
        // running service can reach `.starting` or `.ready` before this window existed — and a state
        // change with no callback attached is a state nobody ever hears. Applying the one it already
        // reached hands that answer on. Later changes arrive through the callback above; both run on
        // the main queue, so no state is delivered twice.
        if service.state != .idle {
            apply(service.state)
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
            takeSurfaceForService()
            splash.showStopped()
        case .starting(let message):
            takeSurfaceForService()
            splash.showStarting(message)
        case .ready(let url):
            // The surface stays up until the page has painted, so the hand-over never shows the
            // bare window. A reload is the only case that has to wait for the web view again.
            LaunchTrace.mark("service ready")
            // A page that has been handed over and has not been replaced since *is* the document
            // this URL describes, so a second `.ready` for it has nothing to load — and revealing it
            // is right, because that document is still on screen.
            if hasRevealedPage, page.isRevealed {
                revealPage("already loaded")
            } else {
                LaunchTrace.mark("navigate")
                page.load(url)
                scheduleRevealFallback(after: Self.revealTimeout)
            }
        case .failed(let message):
            takeSurfaceForService()
            splash.showFailure(message)
        }
        // Announced last: the launch's native tail runs on this callback, and the document has to be
        // on its way first — the tail is native work the page's own load should run alongside, not
        // behind.
        if !didAnnounceService, !state.isStarting {
            didAnnounceService = true
            onServiceAnswered?()
        }
    }

    /// Marks the surface as the service's to speak through, which a reload cover must not override.
    private func takeSurfaceForService() {
        splashOwnedByService = true
        quietShown = false
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
        takeSurfaceForService()
        // A relaunch is already under way — the service the page was handed stopped serving, or a
        // child is still booting — and the surface is telling that story. A page failure on top of it
        // would replace "reconnecting" with a dead end the user cannot act on.
        if case .starting = service.state { return }
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
        takeSurfaceForService()
        splash.showPageFailure(preferences.copy.splash.webProcessLostDetail)
    }

    /// Covers a web view that has nothing to draw, whatever took the content away.
    ///
    /// The startup surface is the right cover for a launch, but it is gone for the rest of the
    /// session — `dismiss()` only ever hides it — so every later blank had nothing over it and the
    /// window's own material showed through: the bare shell, which is exactly the surface the shell
    /// exists to hide. Two things empty the view:
    ///
    /// - a navigation committing (a reload, ⌘R, a new port). Until `didCommit` the old document is
    ///   still composited, so this is the exact start of the gap and covering earlier would hide
    ///   content that is still there;
    /// - the WebContent process exiting. The view is empty from that instant, not from the commit of
    ///   the reload that follows it — see the delayed restart in `WebPageController`. This is also
    ///   the case a Mac that slept brings back: a process killed for memory pressure reports itself
    ///   here when the window is drawn again, so nothing has to be probed for it.
    ///
    /// No delay in either: the gap is already open by the time the shell hears about it, and
    /// waiting to see whether it closes would mean showing the material first and the cover
    /// afterwards, i.e. flashing the very thing this exists to hide. A gap short enough to close
    /// before the cover fades in ends with the cover at a fraction of its opacity, which reads as
    /// nothing at all.
    private func coverBlankPage() {
        // A launch and a service restart keep the startup surface up, and it says more than this.
        guard hasRevealedPage, !splashOwnedByService else { return }
        quietShown = true
        // Idempotent, and it revives a cover that is already dissolving — which is what a second
        // ⌘R landing during the first one's fade-out needs.
        splash.showQuiet()
        // Nothing else releases this one: the service stays `ready` through a reload, and a process
        // that never comes back never commits, so without a fallback a blank view would leave the
        // cover up for good. The page's own report releases it as soon as there is something behind
        // it, and this is the backstop for a document that never reports one.
        scheduleRevealFallback(after: Self.revealTimeout)
    }

    /// Asks the page whether it can still draw, and covers it when it cannot.
    ///
    /// The shell has no native way to see that a page went blank while it was away, and most of the
    /// time it has not: a window behind another one, or a Mac that slept, usually comes back with
    /// its page intact. So this asks instead of assuming — an animation frame from the renderer — and
    /// stays completely out of the way when the answer is a frame. Only a page that produces nothing
    /// gets covered, and only then is a restart spent on bringing it back.
    ///
    /// AppKit fires several of these for one wake (system, display, window, app), hence the throttle.
    // private func verifyPageAfterResume() { … }

    /// Hands the window over to the page, and records which signal released it.
    ///
    /// The surface deliberately outlives the service becoming ready: the hand-over is an event from
    /// content that has actually been drawn, not a duration to wait out. `reason` goes into the
    /// launch trace, because "the page reported a frame" and "the fallback gave up waiting" look
    /// identical on screen and differ by ten seconds in the log.
    /// - Parameter reason: which signal released the surface.
    private func revealPage(_ reason: String) {
        revealFallback?.cancel()
        revealFallback = nil
        // A restart may have taken the service away again before the report arrived; keep the
        // surface up in that case rather than dissolving onto a page that is already being replaced.
        guard case .ready = service.state else { return }
        hasRevealedPage = true
        splashOwnedByService = false
        LaunchTrace.mark("painted (\(reason))")
        // The page owns the window from here on; the palette bridge may trust its reports outright.
        page.notePageRevealed()
        if quietShown {
            // The reload cover leaves faster than the startup surface: what is underneath has
            // already painted, so it has nothing left to wait for.
            quietShown = false
            splash.dismiss(fade: Self.quietFadeOut)
        } else {
            splash.dismiss()
        }
    }

    /// Arms the last-resort reveal, replacing any earlier one.
    ///
    /// The page's own paint report is the signal that releases the surface; this is the backstop for
    /// a document that never finishes, and for a reload whose cover would otherwise stay up.
    /// - Parameter delay: seconds from now until the surface gives up waiting.
    private func scheduleRevealFallback(after delay: TimeInterval) {
        revealFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.revealPage("fallback")
        }
        revealFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
