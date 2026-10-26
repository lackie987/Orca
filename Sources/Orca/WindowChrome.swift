import AppKit

/// Window chrome driven by the `dsh-orca-titlebar` plugin: title visibility, the traffic lights and
/// the hover band that reveals them.
///
/// `lightsOnly` (the default) keeps the native chrome transparent with no visible title and shows
/// the real traffic lights over the page's desktop title strip. `hover` hides them until the pointer
/// enters a transparent top band — the Helium-style hover title bar, drawn natively rather than as
/// a web overlay.
final class WindowChrome {
    /// AppKit centers the button cluster in the 28pt titlebar (~17pt below the window top), while
    /// the desktop page centers its header row in the 52px sidebar title strip (~26pt). The lights
    /// sit 9pt above the toggle / new-session icons without this drop.
    private static let lightsDrop: CGFloat = 9

    private let window: NSWindow
    private var hoverBand: HoverBandView?
    private var hideLightsWorkItem: DispatchWorkItem?
    /// Frames AppKit gave the buttons before any drop, so the offset never accumulates.
    private var lightsBaseline: [NSRect] = []
    /// The drop only makes sense while the page draws the title strip; a real titlebar owns the row.
    private var usesWebTitleStrip = true

    init(window: NSWindow) {
        self.window = window
    }

    /// Applies the preset the plugin selected, or the persisted one when it has not spoken yet.
    func apply(_ raw: String) {
        switch TitleBarMode.parse(raw) {
        case .hidden:
            usesWebTitleStrip = true
            setChrome(transparent: true, lightsHidden: true)
            disableHover()
        case .hover:
            usesWebTitleStrip = true
            setChrome(transparent: true, lightsHidden: true)
            enableHover()
        case .lightsOnly:
            usesWebTitleStrip = true
            setChrome(transparent: true, lightsHidden: false)
            disableHover()
        case .shown:
            usesWebTitleStrip = false
            setChrome(transparent: false, lightsHidden: false)
            disableHover()
        }
        alignTrafficLights()
    }

    /// Moves the traffic lights onto the page's header row. Safe to call after any AppKit layout
    /// pass: the buttons are placed from the captured baseline, never from their current frame.
    func alignTrafficLights() {
        guard usesWebTitleStrip else {
            restoreLightsBaseline()
            return
        }
        let buttons = trafficLights
        guard let parent = buttons.first?.superview,
              !buttons.isEmpty,
              buttons.allSatisfy({ $0.frame.height > 0 })
        else { return }
        if lightsBaseline.count != buttons.count {
            lightsBaseline = buttons.map(\.frame)
        }
        let dy = parent.isFlipped ? Self.lightsDrop : -Self.lightsDrop
        for (button, baseline) in zip(buttons, lightsBaseline) {
            var target = baseline
            target.origin.y += dy
            if button.frame != target {
                button.frame = target
            }
        }
    }

    /// Returns the buttons to where AppKit put them, for the standard-titlebar preset.
    private func restoreLightsBaseline() {
        guard !lightsBaseline.isEmpty else { return }
        for (button, baseline) in zip(trafficLights, lightsBaseline) where button.frame != baseline {
            button.frame = baseline
        }
    }

    /// Sets window chrome. The desktop page reserves its own sidebar title strip, so the web view
    /// stays full-height instead of being inset a second time.
    private func setChrome(transparent: Bool, lightsHidden: Bool) {
        window.titleVisibility = transparent ? .hidden : .visible
        window.titlebarAppearsTransparent = transparent
        window.titlebarSeparatorStyle = transparent ? .none : .automatic
        for button in trafficLights {
            button.isHidden = lightsHidden
        }
        window.contentView?.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// The three standard buttons, in close / minimise / zoom order.
    private var trafficLights: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
    }

    /// Surfaces the real traffic lights while the pointer is in the top band.
    private func enableHover() {
        guard let contentView = window.contentView else { return }
        if hoverBand == nil {
            let band = HoverBandView()
            band.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(band)
            NSLayoutConstraint.activate([
                band.topAnchor.constraint(equalTo: contentView.topAnchor),
                band.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                band.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                // The buttons sit `lightsDrop` lower than AppKit's default, so the band has to
                // reach past them or the pointer loses the lights while still on a button.
                band.heightAnchor.constraint(equalToConstant: 28 + Self.lightsDrop),
            ])
            hoverBand = band
        }
        hoverBand?.onHover = { [weak self] entered in
            self?.showLights(entered)
        }
    }

    private func disableHover() {
        hoverBand?.removeFromSuperview()
        hoverBand = nil
        hideLightsWorkItem?.cancel()
        hideLightsWorkItem = nil
    }

    /// Shows or hides the traffic lights with a short fade; exits are delayed before fading so the
    /// pointer can travel from the band onto a button without the lights vanishing underneath it.
    private func showLights(_ visible: Bool) {
        hideLightsWorkItem?.cancel()
        hideLightsWorkItem = nil
        let buttons = trafficLights
        if visible {
            for button in buttons {
                button.alphaValue = 0
                button.isHidden = false
            }
            Self.fade(buttons, to: 1)
        } else {
            let item = DispatchWorkItem {
                Self.fade(buttons, to: 0) {
                    for button in buttons {
                        button.isHidden = true
                    }
                }
            }
            hideLightsWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
        }
    }

    /// Fades the given buttons as one group, running `completion` after the animation ends.
    private static func fade(_ buttons: [NSButton], to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.18
                for button in buttons {
                    button.animator().alphaValue = alpha
                }
            },
            completionHandler: completion
        )
    }
}

/// Transparent band over the top of the content view that reveals the traffic lights on hover.
/// `hitTest` returns nil so it never intercepts clicks or drags meant for the web content below.
private final class HoverBandView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
