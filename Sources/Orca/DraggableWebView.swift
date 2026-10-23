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
}
