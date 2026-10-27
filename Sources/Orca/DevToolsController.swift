import AppKit

/// Whether the panel draws itself on the light or the dark plane.
///
/// Derived from the theme base colour the page publishes rather than from `NSApp.appearance`: the
/// page can follow the system while its own palette stays dark, and the panel belongs to the page.
enum DevToolsAppearance: String {
    case dark
    case light
}

/// Owns the developer tools: the docked panel, the front end that draws it, and the F12 shortcut.
///
/// The panel keeps no copy of the page state. Everything it shows is either an event the page's
/// agent pushed or an answer to a command, so a reload cannot leave a stale console behind:
/// `pageWillReload` drops the readiness flag and the panel re-asks when the new document reports in.
final class DevToolsController {
    let panel = DevToolsPanelView()

    private let page: DevToolsPageBridge
    private let preferences: Preferences
    /// The panel's own web view; kept reachable so the shell can drive it without a second channel.
    let frontend = DevToolsFrontend()

    private var isOpen = false
    private var pageIsReady = false
    private var appearance: DevToolsAppearance = .dark
    private var baseColor = ""
    private var keyMonitor: Any?

    init(page: DevToolsPageBridge, preferences: Preferences) {
        self.page = page
        self.preferences = preferences

        panel.attach(frontend.webView)
        panel.onHeightChange = { [weak self] height in
            self?.preferences.devToolsHeight = Double(height)
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
        panel.open(height: CGFloat(preferences.devToolsHeight))
        frontend.send(["type": "visibility", "open": true])
        // The panel has been open before, possibly on another theme: hand it the current one.
        frontend.send(themeMessage())
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        panel.close()
        frontend.send(["type": "visibility", "open": false])
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

    // MARK: - Page events

    /// Reports one event pushed by the page's agent.
    func receive(channel: String, payload: Any) {
        switch channel {
        case "ready":
            pageIsReady = true
            frontend.send(["type": "page", "ready": true])
        case "console", "network":
            frontend.send(["type": "event", "channel": channel, "payload": payload])
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
            ])
        case "command":
            let name = message["name"] as? String ?? ""
            let args = message["args"] as? [String: Any] ?? [:]
            guard pageIsReady else {
                reply(["error": "The page has not reported its developer-tools agent yet"])
                return
            }
            page.devToolsCall(["name": name, "args": args], completion: reply)
        case "panel":
            if message["name"] as? String == "close" {
                hide()
            }
            reply(nil)
        default:
            reply(nil)
        }
    }

    private func themePayload() -> [String: Any] {
        ["appearance": appearance.rawValue, "base": baseColor]
    }

    private func themeMessage() -> [String: Any] {
        ["type": "theme", "theme": themePayload()]
    }

    // MARK: - Shortcut

    /// F12 and ⌥⌘I toggle the panel, whatever has focus inside the window.
    ///
    /// A local monitor is used instead of a menu key equivalent because the page's own key handling
    /// runs first for anything the web view receives: the combination has to be taken before the
    /// page sees it, and swallowed so it cannot also reach the app behind the window.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.panel.window,
                  Self.isToggle(event)
            else { return event }
            self.toggle()
            return nil
        }
    }

    private static func isToggle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty && event.keyCode == KeyCode.f12 {
            return true
        }
        return modifiers == [.command, .option] && event.keyCode == KeyCode.i
    }

    private enum KeyCode {
        /// `kVK_F12`; the fn modifier macOS adds is ignored, so fn+F12 works too.
        static let f12: UInt16 = 111
        /// `kVK_ANSI_I`.
        static let i: UInt16 = 34
    }
}
