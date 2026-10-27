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
    /// View under the web view. It carries the theme base so no gap shows the default window grey.
    private var contentBackdrop: NSView?
    /// The page and the startup surface, i.e. everything the developer-tools panel takes space from.
    /// Safety net for a page that never reports it finished; the surface must not outlive it forever.
    private var revealFallback: DispatchWorkItem?

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

        // Apply the persisted preset at launch so the traffic lights are correct from the first frame.
        chrome.apply(preferences.titleBarMode)
        // AppKit lays the titlebar out once the window is on screen; align after that first pass.
        DispatchQueue.main.async { [weak self] in
            self?.chrome.alignTrafficLights()
        }

        // Paint the last base colour the theme published before the service has even started, so
        // the startup surface already belongs to the page's own plane.
        paintBase(ColorHex.color(preferences.splashBaseColor))

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

    func windowDidResize(_ notification: Notification) {
        // AppKit re-places the standard buttons on every titlebar layout.
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
        window.backgroundColor = .windowBackgroundColor
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
        contentBackdrop = container

        // WebKit docks its own inspector inside the web view, so the shell has nothing to lay out
        // for it: the page and the startup surface just fill the window as before.
        Layout.fill(page.webView, splash, in: container)
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
        page.onPageLoadFailed = { [weak self] in
            self?.revealPage()
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
            AppIconInstaller.applyCurrent(preferences, forApp: Bundle.main.bundlePath)
        }
    }

    /// Puts the theme base behind both the page and the startup surface.
    ///
    /// The web view draws no background of its own, so every gap — the first paint, a reload, the
    /// moment the splash fades — shows whatever sits under it. Keeping that colour on the container
    /// means those gaps are the page's own plane instead of the default window grey.
    private func paintBase(_ color: NSColor?) {
        splash.baseColor = color
        contentBackdrop?.layer?.backgroundColor = color?.usingColorSpace(.sRGB)?.cgColor
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
            if loadedURL != url {
                loadedURL = url
                page.load(url)
                scheduleRevealFallback()
            } else {
                revealPage()
            }
        case .failed(let message):
            splash.showFailure(message)
        }
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
