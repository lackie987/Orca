import AppKit

/// The docked developer-tools surface: a hairline, a grab strip and the panel's web view.
///
/// It is pinned to the bottom of the window and owns the height that the divider drags, so nothing
/// else has to know how the panel is laid out. Closed is a zero height plus `isHidden`, not a
/// removal: the frontend keeps running (and keeps its console scroll position) while hidden, the
/// same way Chrome keeps its panel alive between F12 presses.
final class DevToolsPanelView: NSView {
    private enum Metrics {
        static let minimumHeight: CGFloat = 140
        static let defaultHeight: CGFloat = 320
        static let gripHeight: CGFloat = 5
        /// Share of the window the panel may take before it stops growing.
        static let maximumShare: CGFloat = 0.85
    }

    /// Called after a divider drag, with the height to remember for the next launch.
    var onHeightChange: ((CGFloat) -> Void)?

    private let content = NSView()
    private let divider = NSView()
    private let grip = PanelGripView()
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor

        for view in [content, divider, grip] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            // The grab strip is a row of its own instead of an overlay, so it can never swallow a
            // click meant for the panel's first row.
            grip.topAnchor.constraint(equalTo: divider.bottomAnchor),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: Metrics.gripHeight),

            content.topAnchor.constraint(equalTo: grip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightConstraint,
        ])

        grip.onDrag = { [weak self] delta in self?.resize(by: delta) }
        grip.onDragEnd = { [weak self] in
            guard let self else { return }
            self.onHeightChange?(self.heightConstraint.constant)
        }
        grip.onReset = { [weak self] in
            guard let self else { return }
            self.heightConstraint.constant = self.clamp(Metrics.defaultHeight)
            self.onHeightChange?(self.heightConstraint.constant)
        }

        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("Orca does not support nib loading")
    }

    /// Puts the panel's web view inside the surface, pinned to every edge.
    func attach(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Colours the surface behind the panel, so the hand-over to its first paint is invisible.
    func setBackground(_ color: NSColor?) {
        layer?.backgroundColor = color?.usingColorSpace(.sRGB)?.cgColor
    }

    func open(height: CGFloat) {
        isHidden = false
        heightConstraint.constant = clamp(height)
    }

    func close() {
        isHidden = true
        heightConstraint.constant = 0
    }

    // MARK: - Private

    private func resize(by delta: CGFloat) {
        heightConstraint.constant = clamp(heightConstraint.constant + delta)
    }

    private func clamp(_ height: CGFloat) -> CGFloat {
        let available = superview?.bounds.height ?? Metrics.defaultHeight * 3
        let ceiling = max(Metrics.minimumHeight, available * Metrics.maximumShare)
        return min(max(height, Metrics.minimumHeight), ceiling)
    }
}

/// The strip above the panel that resizes it, with the double-click reset.
private final class PanelGripView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var lastY: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        let y = event.locationInWindow.y
        // The panel is anchored to the bottom edge, so dragging the divider up enlarges it.
        onDrag?(y - lastY)
        lastY = y
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }
}
