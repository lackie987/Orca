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
    /// How long a queued element-selection request waits for the front end. The first open builds
    /// the inspector UI from scratch, which is far slower than every reopen after it.
    private static let frontEndTimeout: TimeInterval = 8
    /// The "did not open" verdict must not race a cold front end, which can need close to a second.
    private static let verificationDelay: TimeInterval = 3

    private weak var page: InspectorPage?
    private var keyMonitor: Any?
    /// Pending "did it actually open" check, so a second press can cancel the first one's verdict.
    private var pendingVerification: DispatchWorkItem?
    /// Repeating "is the front end up yet" check for a queued element-selection request.
    private var selectionTimer: Timer?
    private var hasReportedUnavailable = false

    init(page: InspectorPage) {
        self.page = page
        installKeyMonitor()
    }

    deinit {
        pendingVerification?.cancel()
        selectionTimer?.invalidate()
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
        // A queued element-selection request must not fire after the user closed the inspector.
        cancelPendingSelection()
        _ = inspector()?.perform(NSSelectorFromString("hide"))
    }

    /// ⌘⇧C is the inspector's own "Start/Stop element selection" toggle — the same mode as Safari's
    /// crosshair button and the page's "Inspect Element" item. Like those it is *sticky*: a press
    /// starts picking, the next click selects that node in the Elements panel, and picking stays on
    /// so further clicks keep selecting — press ⌘⇧C again (or Esc) to stop.
    ///
    /// The picker lives in the inspector front end, which opens in its own process. Toggling it
    /// before that front end exists (or while its document is still loading) only flips the backend,
    /// with nothing on screen to drive or exit the mode, so a first press opens the inspector and
    /// waits until the front end is usable before toggling. ⌘⇧C is bound *only* here, in the single
    /// keyboard monitor — the menu item carries no shortcut — so a press can never toggle twice and
    /// make the picker flicker on then straight back off.
    func selectElement() {
        guard let inspector = inspector() else { return }
        if isVisible, isFrontEndReady(inspector) {
            // Already up: every press flips the picker, like Safari. A queued request from a cold
            // open must not also fire now, or the two would cancel each other out.
            cancelPendingSelection()
            toggleElementSelection(on: inspector)
            return
        }
        if !isVisible {
            show()
        }
        waitForFrontEnd { [weak self] in
            guard let self, let inspector = self.inspector() else { return }
            // A reopen can restore a picker that was left on; only start it when it is off, so a
            // re-entrant call can never toggle it twice.
            if (inspector.value(forKey: "isElementSelectionActive") as? Bool) == true { return }
            self.toggleElementSelection(on: inspector)
        }
    }

    private func toggleElementSelection(on inspector: NSObject) {
        _ = inspector.perform(NSSelectorFromString("toggleElementSelection"))
    }

    /// Runs `action` once the inspector front end is visible and loaded, or gives up after the
    /// timeout. A second request replaces the pending one so presses cannot stack duplicate toggles.
    private func waitForFrontEnd(then action: @escaping () -> Void) {
        cancelPendingSelection()
        let deadline = Date(timeIntervalSinceNow: Self.frontEndTimeout)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard let inspector = self.inspector() else {
                self.cancelPendingSelection()
                return
            }
            if self.isVisible, self.isFrontEndReady(inspector) {
                self.cancelPendingSelection()
                action()
            } else if Date() >= deadline {
                self.cancelPendingSelection()
            }
        }
        selectionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPendingSelection() {
        selectionTimer?.invalidate()
        selectionTimer = nil
    }

    // MARK: - Inspector handle

    /// The inspector object belongs to the web view; it exists from the moment the view is created.
    private func inspector() -> NSObject? {
        guard let webView = page?.webView else { return nil }
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.value(forKey: "_inspector") as? NSObject
    }

    /// Whether WebKit has built and loaded the inspector UI. Visibility alone is not enough: the
    /// dock can be on screen while its front-end document is still loading.
    private func isFrontEndReady(_ inspector: NSObject) -> Bool {
        guard let front = inspector.value(forKey: "inspectorWebView") as? WKWebView else { return false }
        return front.url != nil && !front.isLoading
    }

    private func frontEnd() -> WKWebView? {
        inspector()?.value(forKey: "inspectorWebView") as? WKWebView
    }

    /// The front end lives in its own process, so "did it open" can only be answered a moment later.
    ///
    /// A missing front end is the real failure signature: without `get-task-allow`, `show` is a
    /// silent no-op and `inspectorWebView` never appears. Visibility alone would be a false alarm —
    /// a cold front end can take close to a second to load, and a sheet saying the inspector did not
    /// open would cover the inspector the user just asked for.
    private func verifyVisible() {
        pendingVerification?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingVerification = nil
            guard !self.isVisible, self.frontEnd() == nil else {
                // A later successful show clears the warning, so a fixed build stops nagging.
                self.hasReportedUnavailable = false
                return
            }
            self.cancelPendingSelection()
            self.reportUnavailable()
        }
        pendingVerification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.verificationDelay, execute: work)
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

    /// F12 and ⌥⌘I toggle the inspector, ⌘⇧C toggles the element picker.
    ///
    /// A local monitor is used instead of menu key equivalents because the page's own key handling
    /// runs first for anything the web view receives: the combination has to be taken before the
    /// page sees it, and swallowed so it cannot also reach the app behind the window.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.page?.webView.window else { return event }
            guard let shortcut = Self.shortcut(for: event) else { return event }
            // A held key must not toggle the inspector or the picker over and over.
            guard !event.isARepeat else { return nil }
            switch shortcut {
            case .toggle:
                self.toggle()
            case .pick:
                self.selectElement()
            }
            return nil
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
