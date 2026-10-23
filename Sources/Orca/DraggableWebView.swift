import AppKit
import WebKit

/// Web view that turns drags starting in the page header into native window moves.
///
/// The window hides its traffic lights and runs full-bleed, so the page header is the drag
/// handle. The reported `dragZoneHeight` follows the measured page header; clicks are always
/// forwarded to the web process first, so buttons inside the header keep working.
final class DraggableWebView: WKWebView {
    /// Height of the draggable band measured from the top of the view.
    var dragZoneHeight: CGFloat = 40

    private var pressedInDragZone = false

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let distanceFromTop = isFlipped ? point.y : bounds.height - point.y
        pressedInDragZone = bounds.height > dragZoneHeight * 2 && distanceFromTop <= dragZoneHeight
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if pressedInDragZone || event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedInDragZone = false
        super.mouseUp(with: event)
    }
}
