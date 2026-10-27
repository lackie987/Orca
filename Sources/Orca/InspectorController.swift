import AppKit
import WebKit

/// A web view the inspector can be attached to; lets the controller be tested without the shell.
protocol InspectorPage: AnyObject {
    var webView: WKWebView { get }
}

/// Drives WebKit's own Web Inspector for the page.
///
/// There is no public API for it: `_WKInspector` is what the "Inspect Element" context-menu item and
/// Safari's Develop menu use, and it is the whole Web Inspector — Elements, Console, Sources,
/// Network, Timelines, Storage — docked inside the web view. WebKit only builds that front end when
/// the process is debuggable, i.e. signed with `com.apple.security.get-task-allow`
/// (`Resources/Orca.entitlements`, applied by `build.sh`). Without the entitlement `show` does
/// nothing at all, so this controller checks afterwards and says so instead of looking broken.
final class InspectorController {
    private weak var page: InspectorPage?
    private var keyMonitor: Any?
    /// Pending "did it actually open" check, so a second press can cancel the first one's verdict.
    private var pendingVerification: DispatchWorkItem?
    private var hasReportedUnavailable = false

    init(page: InspectorPage) {
        self.page = page
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    var isVisible: Bool {
        (inspector()?.value(forKey: "isVisible") as? Bool) ?? false
    }

    // MARK: - Commands

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let inspector = inspector() else {
            reportUnavailable()
            return
        }
        _ = inspector.perform(NSSelectorFromString("show"))
        verifyVisible()
    }

    /// Opens the inspector straight to its Console panel.
    func showConsole() {
        guard let inspector = inspector() else {
            reportUnavailable()
            return
        }
        _ = inspector.perform(NSSelectorFromString("showConsole"))
        verifyVisible()
    }

    func hide() {
        // Pressing F12 twice quickly must not look like a failure: the check belongs to the show
        // that asked for it, and hiding is a deliberate answer, not a broken inspector.
        pendingVerification?.cancel()
        pendingVerification = nil
        _ = inspector()?.perform(NSSelectorFromString("hide"))
    }

    /// Turns on the inspector's own element picker: hovering highlights, clicking selects that node
    /// in the Elements panel. Same mode as the toolbar's crosshair button.
    func selectElement() {
        if !isVisible {
            show()
        }
        guard let inspector = inspector() else { return }
        if (inspector.value(forKey: "isElementSelectionActive") as? Bool) == true {
            return
        }
        _ = inspector.perform(NSSelectorFromString("toggleElementSelection"))
    }

    // MARK: - Inspector handle

    /// The inspector object belongs to the web view; it exists from the moment the view is created.
    private func inspector() -> NSObject? {
        guard let webView = page?.webView else { return nil }
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.value(forKey: "_inspector") as? NSObject
    }

    /// The front end lives in its own process, so "did it open" can only be answered a moment later.
    private func verifyVisible() {
        pendingVerification?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingVerification = nil
            guard !self.isVisible else {
                // A later successful show clears the warning, so a fixed build stops nagging.
                self.hasReportedUnavailable = false
                return
            }
            self.reportUnavailable()
        }
        pendingVerification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func reportUnavailable() {
        guard !hasReportedUnavailable else { return }
        hasReportedUnavailable = true
        let alert = NSAlert()
        alert.messageText = "Web Inspector did not open"
        alert.informativeText = """
        WebKit only builds its inspector for a debuggable process. This copy of Orca is missing the \
        com.apple.security.get-task-allow entitlement, so the inspector is a no-op.

        Rebuild with ./build.sh — it signs the app with Resources/Orca.entitlements, which carries \
        that entitlement.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // A sheet keeps the app responsive; runModal() would freeze the page behind the warning.
        if let window = page?.webView.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Shortcuts

    /// F12 and ⌥⌘I toggle the inspector, ⌘⇧C starts the element picker.
    ///
    /// A local monitor is used instead of menu key equivalents because the page's own key handling
    /// runs first for anything the web view receives: the combination has to be taken before the
    /// page sees it, and swallowed so it cannot also reach the app behind the window.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.page?.webView.window else { return event }
            switch Self.shortcut(for: event) {
            case .toggle:
                self.toggle()
                return nil
            case .pick:
                self.selectElement()
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
