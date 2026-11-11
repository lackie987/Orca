import AppKit
import WebKit

/// Web view that turns drags starting in the page header into native window moves.
///
/// The window hides its traffic lights and runs full-bleed, so the page header is the drag
/// handle. The reported `dragZoneHeight` bounds the drag band; clicks are forwarded to the web
/// process first so buttons inside the header keep working, and a double click on the band
/// zooms the window (maximize / restore).
final class DraggableWebView: WKWebView {
    /// Height of the draggable band measured from the top of the view.
    var dragZoneHeight: CGFloat = 40

    private var pressedInDragZone = false
    /// Window-space location of the active mouse-down, used to tell a drag from a click.
    private var mouseDownPoint = NSPoint.zero

    /// Whether the event lands inside the top drag band that doubles as the title bar.
    private func isInsideDragZone(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let distanceFromTop = isFlipped ? point.y : bounds.height - point.y
        return bounds.height > dragZoneHeight * 2 && distanceFromTop <= dragZoneHeight
    }

    override func mouseDown(with event: NSEvent) {
        // A double click on the title band zooms the window (maximize / restore).
        if event.clickCount == 2 && isInsideDragZone(event) {
            pressedInDragZone = false
            window?.performZoom(nil)
            return
        }
        mouseDownPoint = event.locationInWindow
        pressedInDragZone = isInsideDragZone(event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // Command-drag moves the window from anywhere, regardless of the drag band.
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        // Require a small move before dragging so a double click never starts a drag.
        if pressedInDragZone {
            let delta = hypot(event.locationInWindow.x - mouseDownPoint.x,
                              event.locationInWindow.y - mouseDownPoint.y)
            if delta >= 4 {
                window?.performDrag(with: event)
                return
            }
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedInDragZone = false
        super.mouseUp(with: event)
    }

    // MARK: - Key equivalents

    /// The page must not swallow a combination the shell's own menu already draws.
    ///
    /// `WKWebView` answers `true` to `performKeyEquivalent` for combinations the page prevents —
    /// dsh is an Electron app, so its page carries a keyboard layer of its own. That took ⌘W away
    /// from the File menu: the item stayed visible and enabled while `performClose:` never ran, so
    /// the shortcut looked broken. Declining the combination here lets AppKit's normal dispatch
    /// reach the item that draws it, which keeps the menu the single place a shortcut executes.
    ///
    /// Only items the menu visibly lists count. AppKit also installs hidden duplicates (⌘F next to
    /// ⌘⌃F, for instance) that exist for another app's convention; those must keep losing to the
    /// page, or a shortcut the page owns would silently toggle something else.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.menuClaims(event) { return false }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether a visible item of the main menu carries this combination.
    ///
    /// Matching only reads the menu; a disabled item still claims its key, and letting the menu
    /// answer keeps one execution path instead of running an action from inside the web view.
    private static func menuClaims(_ event: NSEvent) -> Bool {
        guard let main = NSApp.mainMenu,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              !key.isEmpty
        else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        func search(_ menu: NSMenu) -> Bool {
            for item in menu.items {
                if let action = item.action, editingActions.contains(NSStringFromSelector(action)) {
                    // The focused editor answers these, and the page's editor is not the same one
                    // WebKit reaches: ⌘Z resolves to the window's undo manager, not the composer's.
                    continue
                }
                if !item.isHidden,
                   !item.keyEquivalent.isEmpty,
                   item.keyEquivalent.lowercased() == key,
                   item.keyEquivalentModifierMask == flags {
                    return true
                }
                if let submenu = item.submenu, search(submenu) { return true }
            }
            return false
        }
        return search(main)
    }

    /// The menu's editing commands, which stay with whatever holds focus.
    ///
    /// These are the only combinations the page keeps even though the menu draws them: the shell
    /// has nothing to add to a copy or an undo, and taking them would change which implementation
    /// of the command runs inside the page's own editors.
    private static let editingActions: Set<String> = [
        "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
    ]
}
