import AppKit

/// The docked developer-tools surface: a hairline, a grab strip and the panel's web view.
///
/// It is pinned to one edge of the window and owns the size the divider drags, so nothing else has
/// to know how the panel is laid out. Closed is a zero size plus `isHidden`, not a removal: the
/// frontend keeps running (and keeps its console scroll position) while hidden, the same way Chrome
/// keeps its panel alive between F12 presses.
final class DevToolsPanelView: NSView {
    private enum Metrics {
        static let minimumSize: CGFloat = 140
        static let defaultSize: CGFloat = 320
        static let defaultWidth: CGFloat = 420
        static let gripThickness: CGFloat = 5
        /// Share of the window the panel may take before it stops growing.
        static let maximumShare: CGFloat = 0.85
    }

    /// Called after a divider drag, with the size to remember for the next launch.
    var onSizeChange: ((CGFloat) -> Void)?

    private(set) var dock: DevToolsDock = .bottom

    private let content = NSView()
    private let divider = NSView()
    private let grip = PanelGripView()
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)
    private var edgeConstraints: [NSLayoutConstraint] = []

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

        grip.onResize = { [weak self] delta in self?.resize(by: delta) }
        grip.onResizeEnd = { [weak self] in
            guard let self else { return }
            self.onSizeChange?(self.size)
        }
        grip.onReset = { [weak self] in
            guard let self else { return }
            self.setSize(self.dock == .bottom ? Metrics.defaultSize : Metrics.defaultWidth)
            self.onSizeChange?(self.size)
        }

        apply(dock: .bottom)
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

    /// Rebuilds the inner layout for the given edge: the divider and the grab strip move to it.
    func apply(dock newDock: DevToolsDock) {
        guard newDock != dock || edgeConstraints.isEmpty else { return }
        dock = newDock
        NSLayoutConstraint.deactivate(edgeConstraints)
        heightConstraint.isActive = false
        widthConstraint.isActive = false

        grip.dock = newDock
        edgeConstraints = newDock == .bottom ? bottomLayout() : rightLayout()
        NSLayoutConstraint.activate(edgeConstraints)
        NSLayoutConstraint.activate([newDock == .bottom ? heightConstraint : widthConstraint])
    }

    func open(size: CGFloat) {
        isHidden = false
        setSize(size)
    }

    func close() {
        isHidden = true
        setHeightOrWidth(0)
    }

    /// Current size along the docked edge, used when the divider drag ends.
    var size: CGFloat {
        dock == .bottom ? heightConstraint.constant : widthConstraint.constant
    }

    // MARK: - Private

    private func bottomLayout() -> [NSLayoutConstraint] {
        [
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            // The grab strip is a row of its own instead of an overlay, so it can never swallow a
            // click meant for the panel's first row.
            grip.topAnchor.constraint(equalTo: divider.bottomAnchor),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: Metrics.gripThickness),

            content.topAnchor.constraint(equalTo: grip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
    }

    private func rightLayout() -> [NSLayoutConstraint] {
        [
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            grip.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: Metrics.gripThickness),

            content.leadingAnchor.constraint(equalTo: grip.trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
    }

    private func resize(by delta: CGFloat) {
        setSize(size + delta)
    }

    private func setSize(_ value: CGFloat) {
        setHeightOrWidth(clamp(value))
    }

    private func setHeightOrWidth(_ value: CGFloat) {
        if dock == .bottom {
            heightConstraint.constant = value
        } else {
            widthConstraint.constant = value
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        let available = dock == .bottom
            ? (superview?.bounds.height ?? Metrics.defaultSize * 3)
            : (superview?.bounds.width ?? Metrics.defaultSize * 4)
        let ceiling = max(Metrics.minimumSize, available * Metrics.maximumShare)
        return min(max(value, Metrics.minimumSize), ceiling)
    }
}

/// The strip along the panel's inner edge that resizes it, with the double-click reset.
private final class PanelGripView: NSView {
    var dock: DevToolsDock = .bottom {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// A vertical drag grows a bottom-docked panel; a horizontal one grows a right-docked panel.
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    var onReset: (() -> Void)?

    private var lastPoint = NSPoint.zero

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dock == .bottom ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        lastPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        switch dock {
        case .bottom:
            // Anchored to the bottom edge, so dragging the divider up enlarges the panel.
            onResize?(point.y - lastPoint.y)
        case .right:
            // Anchored to the right edge, so dragging the divider left enlarges the panel.
            onResize?(lastPoint.x - point.x)
        }
        lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        onResizeEnd?()
    }
}
