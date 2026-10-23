import AppKit

/// The main Orca window: vibrancy backdrop, web UI, native drag regions and the startup splash.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// Invoked when the splash or a menu asks for the settings panel.
    var onRequestSettings: (() -> Void)?

    private let service: ServiceController
    private let preferences: Preferences
    private let page: WebPageController
    private let splash = SplashView()
    private var loadedURL: URL?

    init(service: ServiceController, preferences: Preferences) {
        self.service = service
        self.preferences = preferences
        self.page = WebPageController(preferences: preferences)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window)
        buildContent(in: window)
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

    @objc func toggleInspector(_ sender: Any?) {
        if !preferences.developerExtras {
            preferences.developerExtras = true
            page.applyPreferences()
        }
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard page.webView.responds(to: inspectorSelector),
              let inspector = page.webView.value(forKey: "_inspector") as? NSObject
        else {
            NSSound.beep()
            return
        }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) {
            inspector.perform(show)
        }
    }

    @objc func openInBrowser(_ sender: Any?) {
        guard let url = service.accessURL else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func copyAccessLink(_ sender: Any?) {
        guard let url = service.accessURL else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
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

    func windowDidEnterFullScreen(_ notification: Notification) {
        page.applyFullscreen(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        page.applyFullscreen(false)
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

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    private func buildContent(in window: NSWindow) {
        let container = NSView()
        container.wantsLayer = true
        window.contentView = container

        page.webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page.webView)

        splash.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splash)

        for view in [page.webView, splash] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
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
        splash.onOpenSettings = { [weak self] in
            self?.onRequestSettings?()
        }
    }

    private func apply(_ state: ServiceState) {
        switch state {
        case .idle:
            splash.showStopped()
        case .starting(let message):
            splash.showStarting(message)
        case .ready(let url):
            if loadedURL != url {
                loadedURL = url
                page.load(url)
            }
            splash.dismiss()
        case .failed(let message):
            splash.showFailure(message)
        }
    }

    private func applyTheme(_ source: String) {
        switch source {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            NSApp.appearance = nil
        }
    }
}
