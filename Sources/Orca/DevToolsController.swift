import AppKit

/// Whether the panel draws itself on the light or the dark plane.
///
/// Derived from the theme base colour the page publishes rather than from `NSApp.appearance`: the
/// page can follow the system while its own palette stays dark, and the panel belongs to the page.
enum DevToolsAppearance: String {
    case dark
    case light
}

/// Owns the developer tools: the docked panel, the front end that draws it, and the shortcuts.
///
/// The panel keeps no copy of the page state. Everything it shows is either an event the page's
/// agent pushed or an answer to a command, so a reload cannot leave a stale console behind:
/// `pageWillReload` drops the readiness flag and the panel re-asks when the new document reports in.
///
/// Two kinds of commands reach this object. Page commands are forwarded to the agent; cookies and
/// site data are answered here, because they live in `WKWebsiteDataStore` rather than in the document.
final class DevToolsController {
    let panel = DevToolsPanelView()
    /// The panel's own web view; kept reachable so the shell can drive it without a second channel.
    let frontend = DevToolsFrontend()

    /// Called when the dock edge changes, so the window can move the panel and the page area.
    var onDockChange: ((DevToolsDock) -> Void)?

    private let page: DevToolsPageBridge
    private let preferences: Preferences

    private var isOpen = false
    private var pageIsReady = false
    private var appearance: DevToolsAppearance = .dark
    private var baseColor = ""
    private var keyMonitor: Any?
    private(set) var dock: DevToolsDock = .bottom

    init(page: DevToolsPageBridge, preferences: Preferences) {
        self.page = page
        self.preferences = preferences

        panel.attach(frontend.webView)
        panel.onSizeChange = { [weak self] size in
            self?.remember(size)
        }
        frontend.onMessage = { [weak self] message, reply in
            self?.handle(message, reply: reply)
        }

        applyTheme(base: preferences.splashBaseColor)
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    // MARK: - Visibility

    func toggle() {
        if isOpen {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isOpen else { return }
        isOpen = true
        panel.open(size: storedSize)
        frontend.send(["type": "visibility", "open": true])
        // The panel has been open before, possibly on another theme: hand it the current one.
        frontend.send(themeMessage())
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        panel.close()
        frontend.send(["type": "visibility", "open": false])
        // A pick left armed would keep the page in crosshair mode after the panel is gone.
        if pageIsReady {
            page.devToolsCall(["name": "dom.pick.stop", "args": [:]]) { _ in }
        }
    }

    // MARK: - Dock

    /// Restores the edge the panel was last left on. The window applies the matching constraints.
    func restoreDock() {
        dock = DevToolsDock.stored(preferences.devToolsDock)
        panel.apply(dock: dock)
    }

    func toggleDock() {
        dock = dock == .bottom ? .right : .bottom
        preferences.devToolsDock = dock.rawValue
        panel.apply(dock: dock)
        onDockChange?(dock)
        if isOpen {
            panel.open(size: storedSize)
        }
    }

    private var storedSize: CGFloat {
        CGFloat(dock == .bottom ? preferences.devToolsHeight : preferences.devToolsWidth)
    }

    private func remember(_ size: CGFloat) {
        if dock == .bottom {
            preferences.devToolsHeight = Double(size)
        } else {
            preferences.devToolsWidth = Double(size)
        }
    }

    // MARK: - Theme

    /// Applies the page's theme base colour to the panel and to the surface behind it.
    func applyTheme(base: String) {
        baseColor = base
        let color = ColorHex.color(base)
        appearance = (color.map(ColorHex.isDark) ?? true) ? .dark : .light
        panel.setBackground(color)
        frontend.send(themeMessage())
    }

    // MARK: - Element picker

    /// Arms the page's element picker: hovering highlights, clicking selects, Escape cancels.
    func pickElement() {
        show()
        frontend.send(["type": "pick", "active": true])
        guard pageIsReady else { return }
        page.devToolsCall(["name": "dom.pick.start", "args": [:]]) { _ in }
    }

    // MARK: - Page events

    /// Reports one event pushed by the page's agent.
    func receive(channel: String, payload: Any) {
        switch channel {
        case "ready":
            pageIsReady = true
            frontend.send(["type": "page", "ready": true])
        case "console", "network", "picked", "pickCancelled":
            frontend.send(["type": "event", "channel": channel, "payload": payload])
        case "copy":
            if let text = (payload as? [String: Any])?["text"] as? String {
                copy(text)
            }
        default:
            break
        }
    }

    /// Called when the main frame starts navigating: the agent of the old document is gone.
    func pageWillReload() {
        pageIsReady = false
        frontend.send(["type": "page", "ready": false])
    }

    // MARK: - Panel messages

    private func handle(_ message: [String: Any], reply: @escaping (Any?) -> Void) {
        switch message["kind"] as? String {
        case "init":
            reply([
                "theme": themePayload(),
                "open": isOpen,
                "pageReady": pageIsReady,
                "dock": dock.rawValue,
            ])
        case "command":
            let name = message["name"] as? String ?? ""
            let args = message["args"] as? [String: Any] ?? [:]
            if name.hasPrefix("cookies.") || name == "site.clear" {
                handleSiteCommand(name: name, args: args, reply: reply)
                return
            }
            guard pageIsReady else {
                reply(["error": "The page has not reported its developer-tools agent yet"])
                return
            }
            page.devToolsCall(["name": name, "args": args], completion: reply)
        case "copy":
            if let text = message["text"] as? String {
                copy(text)
            }
            reply(nil)
        case "panel":
            switch message["name"] as? String {
            case "close":
                hide()
            case "dock":
                toggleDock()
            default:
                break
            }
            reply(nil)
        default:
            reply(nil)
        }
    }

    // MARK: - Site data

    private func handleSiteCommand(name: String, args: [String: Any], reply: @escaping (Any?) -> Void) {
        let store = page.devToolsDataStore
        switch name {
        case "cookies.list":
            DevToolsSiteData.listCookies(in: store, completion: reply)
        case "cookies.delete":
            DevToolsSiteData.deleteCookie(args, in: store, completion: reply)
        case "cookies.clear":
            DevToolsSiteData.clearCookies(for: page.devToolsOrigin, in: store, completion: reply)
        case "site.clear":
            guard let origin = page.devToolsOrigin else {
                reply(["error": "The page has no origin yet"])
                return
            }
            // Storage is cleared in the store, but the document keeps its in-memory copy of it —
            // reloading is what makes the page observe the same state the panel now shows.
            DevToolsSiteData.clearSiteData(for: origin, in: store) { [weak self] result in
                self?.page.devToolsReload()
                reply(result)
            }
        default:
            reply(["error": "Unsupported shell command: \(name)"])
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func themePayload() -> [String: Any] {
        ["appearance": appearance.rawValue, "base": baseColor]
    }

    private func themeMessage() -> [String: Any] {
        ["type": "theme", "theme": themePayload()]
    }

    // MARK: - Shortcuts

    /// F12 and ⌥⌘I toggle the panel, ⌘⇧C arms the element picker.
    ///
    /// A local monitor is used instead of menu key equivalents because the page's own key handling
    /// runs first for anything the web view receives: the combination has to be taken before the page
    /// sees it, and swallowed so it cannot also reach the app behind the window.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel.window else { return event }
            switch Self.shortcut(for: event) {
            case .toggle:
                self.toggle()
                return nil
            case .pick:
                self.pickElement()
                return nil
            case nil:
                return event
            }
        }
    }

    private enum Shortcut {
        case toggle
        case pick
    }

    private static func shortcut(for event: NSEvent) -> Shortcut? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // The fn modifier macOS adds to a function key is not part of the comparison, so fn+F12 works.
        if modifiers.isEmpty && event.keyCode == KeyCode.f12 {
            return .toggle
        }
        if modifiers == [.command, .option] && event.keyCode == KeyCode.i {
            return .toggle
        }
        if modifiers == [.command, .shift] && event.keyCode == KeyCode.c {
            return .pick
        }
        return nil
    }

    private enum KeyCode {
        static let f12: UInt16 = 111
        /// `kVK_ANSI_I`.
        static let i: UInt16 = 34
        /// `kVK_ANSI_C`.
        static let c: UInt16 = 8
    }
}
