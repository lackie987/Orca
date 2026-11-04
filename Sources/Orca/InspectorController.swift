import AppKit
import ObjectiveC
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
    /// Rejects WebKit's docking entirely.
    ///
    /// `_WKInspector` docks itself by calling `attach`: that is the path behind the front end's
    /// three dock buttons, the first-open `platformAttach`, and every open that does not come
    /// through this controller (the page's "Inspect Element" context-menu item, for example).
    /// Orca has no split view to arbitrate the space the dock and the page would trade, so every
    /// attach is turned into a detach instead. The inspector can therefore only ever be its own
    /// window, whichever shortcut or menu opened it.
    private static let rejectDocking: Void = {
        guard let inspectorClass = NSClassFromString("_WKInspector") else { return }
        let detachInstead: @convention(block) (AnyObject) -> Void = { inspector in
            InspectorController.sendPrivate("detach", to: inspector as? NSObject)
        }
        _ = class_replaceMethod(
            inspectorClass,
            NSSelectorFromString("attach"),
            imp_implementationWithBlock(detachInstead),
            "v@:"
        )
    }()

    /// How long a queued element-selection request waits for the front end. The first open builds
    /// the inspector UI from scratch, which is far slower than every reopen after it.
    private static let frontEndTimeout: TimeInterval = 8
    /// The "did not open" verdict must not race a cold front end, which can need close to a second.
    private static let verificationDelay: TimeInterval = 3

    private weak var page: InspectorPage?
    private var keyMonitor: Any?
    /// Pending "did it actually open" check, so a second press can cancel the first one's verdict.
    private var pendingVerification: DispatchWorkItem?
    /// Keeps a docked panel from staying docked while the inspector is open.
    private var undockWatcher: Timer?
    /// Repeating "is the front end up yet" check for a queued element-selection request.
    private var selectionTimer: Timer?
    /// Picker state the last press asked for; nil when no request is in flight.
    private var pickerTarget: Bool?
    private var hasReportedUnavailable = false

    init(page: InspectorPage) {
        _ = Self.rejectDocking
        self.page = page
        installKeyMonitor()
    }

    deinit {
        pendingVerification?.cancel()
        selectionTimer?.invalidate()
        undockWatcher?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    // MARK: - Private API

    /// Calls a private selector, but only when the target really answers it.
    ///
    /// Everything this controller touches on `_WKInspector` is private: WebKit can rename or drop a
    /// selector in any release, and `perform(_:)` answers one it does not know with
    /// `NSInvalidArgumentException` — an *uncaught* one, so the app dies on whichever keystroke
    /// happened to reach it first. Checking first turns a vanished selector into a no-op, which is
    /// what the "inspector did not open" alert already explains to the user.
    ///
    /// - Returns: whether the selector existed and was called.
    @discardableResult
    private static func sendPrivate(_ name: String, to target: NSObject?) -> Bool {
        guard let target else { return false }
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return false }
        _ = target.perform(selector)
        return true
    }

    /// Reads a private property with the same guard, KVC included: `value(forKey:)` raises
    /// `NSUndefinedKeyException` for a key the class does not carry, which is just as fatal as an
    /// unknown selector.
    private static func readPrivate(_ key: String, from target: NSObject?) -> Any? {
        guard let target, canRead(key, from: target) else { return nil }
        return target.value(forKey: key)
    }

    /// Whether `value(forKey:)` would resolve `key` on `target` rather than raise.
    ///
    /// KVC accepts three routes: a getter named `get<Key>`, a getter named `<key>`, or an instance
    /// variable named `_<key>`. Testing the selectors alone is not enough — a property that is only
    /// backed by its ivar would read as absent, and every `isVisible` check would answer `false`,
    /// which would make the toggle open an already-open inspector instead of closing it.
    private static func canRead(_ key: String, from target: NSObject) -> Bool {
        let capitalized = key.prefix(1).uppercased() + key.dropFirst()
        for name in [key, "get" + capitalized, "is" + capitalized]
        where target.responds(to: NSSelectorFromString(name)) {
            return true
        }
        let type = type(of: target)
        return class_getInstanceVariable(type, "_" + key) != nil
            || class_getInstanceVariable(type, key) != nil
    }

    var isVisible: Bool {
        (Self.readPrivate("isVisible", from: inspector()) as? Bool) ?? false
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
        openDetached("show")
    }

    /// Opens the inspector straight to its Console panel, in its own window.
    func showConsole() {
        openDetached("showConsole")
    }

    /// Opens the inspector in a window of its own; it is never docked into the page.
    ///
    /// WebKit wants to dock the panel by default (`platformAttach`), which is the one thing this
    /// shell cannot arbitrate: the dock and the page trade the window's space, and the page keeps
    /// re-laying out underneath. `detach()` moves the front end into its own window, which is the
    /// only layout Orca supports, and `rejectDocking` turns any later attach into the same
    /// detach.
    private func openDetached(_ command: String) {
        guard let inspector = inspector() else {
            reportUnavailable()
            return
        }
        Self.sendPrivate("detach", to: inspector)
        Self.sendPrivate(command, to: inspector)
        // The first open of a process builds the front end before `detach()` can apply, so that
        // build can finish attached. One more call in the same turn covers it.
        Self.sendPrivate("detach", to: inspector)
        verifyVisible()
        watchForDock()
        // The window may exist by now; the async pass covers the colder first build.
        alignInspectorAppearance()
        DispatchQueue.main.async { [weak self] in self?.alignInspectorAppearance() }
    }

    /// Keeps the panel out of the page for as long as it is open.
    ///
    /// One check per second, and only a single `detach()` per docked observation: re-sending
    /// `detach()` into an ongoing dock animation is exactly what makes the page and the panel
    /// flicker while they fight over the window's space.
    private func watchForDock() {
        undockWatcher?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard let inspector = self.inspector(),
                  (Self.readPrivate("isVisible", from: inspector) as? Bool) == true
            else {
                self.stopWatchingForDock()
                return
            }
            guard let window = self.detachedWindow() else {
                Self.sendPrivate("detach", to: inspector)
                return
            }
            window.appearance = NSApp.appearance
        }
        undockWatcher = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWatchingForDock() {
        undockWatcher?.invalidate()
        undockWatcher = nil
    }

    /// The inspector's own window; nil while it is docked in the page or not built yet.
    private func detachedWindow() -> NSWindow? {
        guard let window = frontEnd()?.window, window !== page?.webView.window else { return nil }
        return window
    }

    /// Keep WebKit's own panel in the same light/dark mode as the page; its chrome and internal
    /// layout remain WebKit's, because DevTools is a separate tool rather than a shell page.
    private func alignInspectorAppearance() {
        detachedWindow()?.appearance = NSApp.appearance
    }

    func hide() {
        // Pressing F12 twice quickly must not look like a failure: the check belongs to the show
        // that asked for it, and hiding is a deliberate answer, not a broken inspector.
        pendingVerification?.cancel()
        pendingVerification = nil
        // A queued element-selection request must not fire after the user closed the inspector.
        cancelPendingSelection()
        stopWatchingForDock()
        // WebKit does not end element selection when the inspector goes away: the page keeps the
        // crosshair and keeps capturing clicks, and the next show then drops every picker toggle, so
        // the mode can never be turned off again. Stop it while the front end still answers.
        stopPicking()
        Self.sendPrivate("hide", to: inspector())
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
        guard inspector() != nil else { return }
        let target = !(pickerTarget ?? isSelectionActive)
        if !target, !isVisible {
            // Picking outlived a closed inspector: stop it without opening the window again.
            stopPicking()
            return
        }
        pickerTarget = target
        if !isVisible {
            show()
        }
        applyPickerTarget()
    }

    private func toggleElementSelection(on inspector: NSObject) {
        Self.sendPrivate("toggleElementSelection", to: inspector)
    }

    /// Applies the request in `pickerTarget` once the inspector front end can answer it.
    private func applyPickerTarget() {
        guard let inspector = inspector(), pickerTarget != nil else { return }
        guard isVisible, isFrontEndReady(inspector) else {
            waitForFrontEnd { [weak self] in self?.applyPickerTarget() }
            return
        }
        // Toggle unconditionally: after a close the front end's flag can lag behind the page, and
        // comparing against it is what turns a stop into a second start. The request itself is the
        // truth, so each press flips exactly one state change.
        toggleElementSelection(on: inspector)
    }

    /// Whether the page is currently in element-picking mode.
    private var isSelectionActive: Bool {
        (Self.readPrivate("isElementSelectionActive", from: inspector()) as? Bool) ?? false
    }

    /// Turns the picker off when it is on, without showing or hiding the window.
    private func stopPicking() {
        let wasPicking = pickerTarget ?? isSelectionActive
        pickerTarget = false
        guard wasPicking, let inspector = inspector() else { return }
        toggleElementSelection(on: inspector)
    }

    /// Runs `action` once the inspector front end is visible and loaded, or gives up after the
    /// timeout. A second request replaces the pending one so presses cannot stack duplicate toggles.
    ///
    /// 150 ms is the front end's own loading granularity — it reports readiness by finishing a
    /// document load, not by a 50 ms deadline — so the denser poll only asked the same question
    /// three times as often for the length of an inspector open.
    private func waitForFrontEnd(then action: @escaping () -> Void) {
        cancelPendingSelection()
        let deadline = Date(timeIntervalSinceNow: Self.frontEndTimeout)
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
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
        guard let front = Self.readPrivate("inspectorWebView", from: inspector) as? WKWebView else {
            return false
        }
        return front.url != nil && !front.isLoading
    }

    private func frontEnd() -> WKWebView? {
        Self.readPrivate("inspectorWebView", from: inspector()) as? WKWebView
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
        alert.messageText = Preferences.shared.copy.alert.inspectorTitle
        alert.informativeText = Preferences.shared.copy.alert.inspectorBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: Preferences.shared.copy.common.ok)
        // A sheet keeps the app responsive; runModal() would freeze the page behind the warning.
        if let window = page?.webView.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Shortcuts

    /// F12 and ⌥⌘I toggle the inspector, ⌘⇧C toggles the element picker, Esc cancels picking.
    ///
    /// A local monitor is used instead of menu key equivalents because the page's own key handling
    /// runs first for anything the web view receives: the combination has to be taken before the
    /// page sees it, and swallowed so it cannot also reach the app behind the window.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.owns(event.window) else { return event }
            guard let shortcut = Self.shortcut(for: event) else { return event }
            // A held key must not toggle the inspector or the picker over and over.
            guard !event.isARepeat else { return nil }
            switch shortcut {
            case .toggle:
                self.toggle()
            case .pick:
                self.selectElement()
            case .escape:
                guard self.handleEscape(fromPage: event.window === self.page?.webView.window) else {
                    return event
                }
            }
            return nil
        }
    }

    /// Whether a key event came from the page's window or from the inspector's own window.
    private func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === page?.webView.window { return true }
        return window === detachedWindow()
    }

    /// One Esc: cancel the picker, and — when the page sent the key — close the inspector too.
    ///
    /// From the page, a single Esc ends everything the inspector was doing there: the picker is
    /// cancelled first and the window closes with it, so the crosshair cannot outlive the panel.
    /// Esc inside the inspector's own window only cancels picking; the rest of its Esc belongs to
    /// the front end (console editing, autocomplete).
    ///
    /// - Parameter fromPage: whether the key came from the page's window rather than the panel's.
    /// - Returns: whether the key was consumed.
    @discardableResult
    func handleEscape(fromPage: Bool) -> Bool {
        if isSelectionActive {
            cancelPendingSelection()
            stopPicking()
            if fromPage {
                hide()
            }
            return true
        }
        guard fromPage, isVisible else { return false }
        hide()
        return true
    }

    private enum Shortcut {
        case toggle
        case pick
        case escape
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
        if modifiers.isEmpty && event.keyCode == KeyCode.escape {
            return .escape
        }
        return nil
    }

    private enum KeyCode {
        static let f12: UInt16 = 111
        /// `kVK_ANSI_I`.
        static let i: UInt16 = 34
        /// `kVK_ANSI_C`.
        static let c: UInt16 = 8
        /// `kVK_Escape`.
        static let escape: UInt16 = 53
    }
}
