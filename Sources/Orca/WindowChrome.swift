import AppKit
import QuartzCore

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

    /// How long the lights take to appear or leave. One number for both directions: the reveal and
    /// the exit are the same motion seen backwards, and two constants drift apart the moment one of
    /// them is retuned.
    private static let lightsFadeDuration: TimeInterval = 0.35

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
        // The chrome change itself can make AppKit re-place the buttons on the next layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.alignTrafficLights()
        }
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
        setLightsHidden(lightsHidden)
        window.contentView?.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// Switches the lights between visible and hidden with the dissolve, so display-mode changes
    /// and the hover band share one animation instead of popping.
    private func setLightsHidden(_ hidden: Bool) {
        let buttons = trafficLights
        guard !buttons.isEmpty else { return }
        hideLightsWorkItem?.cancel()
        hideLightsWorkItem = nil
        if hidden {
            guard buttons.contains(where: { !$0.isHidden }) else { return }
            Self.dissolve(buttons, to: 0) {
                for button in buttons {
                    button.isHidden = true
                }
            }
        } else {
            guard buttons.contains(where: { $0.isHidden || $0.alphaValue < 0.99 }) else { return }
            cancelLightsFade()
            for button in buttons {
                button.alphaValue = 0
                button.isHidden = false
            }
            Self.dissolve(buttons, to: 1)
        }
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
        cancelLightsFade()
    }

    /// Reveals the lights with the shared dissolve and hides them with the stepped fade; the exit is
    /// delayed first, so the pointer can travel from the band onto a button without the lights
    /// vanishing underneath it.
    private func showLights(_ visible: Bool) {
        hideLightsWorkItem?.cancel()
        hideLightsWorkItem = nil
        if visible {
            setLightsHidden(false)
            // Hover mode hides the buttons before the first alignment and AppKit only places them
            // when they are shown again, so align here or they appear at the native titlebar row
            // instead of the page's. A next-runloop pass covers AppKit placing them asynchronously
            // after the visibility change.
            alignTrafficLights()
            DispatchQueue.main.async { [weak self] in
                self?.alignTrafficLights()
            }
        } else {
            let item = DispatchWorkItem { [weak self] in
                self?.fadeOutLights()
            }
            hideLightsWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
        }
    }

    // MARK: - Exit fade

    /// Frame-stepped exit fade; nil when none is running.
    private var lightsFadeTimer: Timer?
    private var lightsFadeStarted: CFTimeInterval = 0
    private var lightsFadeFrom: CGFloat = 1

    /// Fades the lights out and hides them when the fade lands.
    ///
    /// `dissolve` cannot do this one: measured in this window, `animator().alphaValue = 0` is
    /// written in the first frame while the animation group still holds for its full duration —
    /// 1.00 → 0.00 inside one 50ms sample — so the exit reads as a cut. Stepping `alphaValue` from
    /// a timer is the only form AppKit honours here. The reveal keeps `dissolve`: it is short
    /// enough that the jump is not visible, and it stays out of this path on purpose.
    private func fadeOutLights() {
        let buttons = trafficLights
        guard !buttons.isEmpty else { return }
        cancelLightsFade()
        // Any write to these buttons makes AppKit re-place them at its own titlebar row, undoing
        // the `lightsDrop`; re-assert the drop here and on every step so the dissolve happens
        // where the lights actually are instead of 9pt higher.
        alignTrafficLights()
        lightsFadeFrom = buttons[0].alphaValue
        guard lightsFadeFrom > 0.001 else {
            for button in buttons { button.isHidden = true }
            return
        }
        lightsFadeStarted = CACurrentMediaTime()
        // `.common` keeps the ramp alive while the pointer drags or a menu tracks.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepLightsFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        lightsFadeTimer = timer
    }

    private func stepLightsFade() {
        let buttons = trafficLights
        guard !buttons.isEmpty else {
            cancelLightsFade()
            return
        }
        let progress = min(1, (CACurrentMediaTime() - lightsFadeStarted) / Self.lightsFadeDuration)
        // Ease-out: let go of full opacity at once, take the time to reach zero.
        let eased = 1 - pow(1 - progress, 3)
        for button in buttons {
            button.alphaValue = lightsFadeFrom * CGFloat(1 - eased)
        }
        // Writing the alpha is what makes AppKit snap the cluster back to its own row, so the drop
        // has to be re-applied after every step, not once.
        alignTrafficLights()
        guard progress >= 1 else { return }
        cancelLightsFade()
        for button in buttons { button.isHidden = true }
    }

    /// Stops a running exit fade; the caller decides the next alpha.
    private func cancelLightsFade() {
        lightsFadeTimer?.invalidate()
        lightsFadeTimer = nil
    }

    /// Dissolves the given buttons as one group with an eased fade, for both the hover band and the
    /// display-mode switches. Runs `completion` after the animation ends.
    ///
    /// This replaced the plain 0.18s `fade` of the first traffic-light pass, which popped on the way
    /// in and read as a cut on the way out. The exit has since moved to `fadeOutLights`, which steps
    /// the alpha by hand; what is left here is the reveal and the mode switches, where a single
    /// animation group is honoured.
    private static func dissolve(
        _ buttons: [NSButton],
        to alpha: CGFloat,
        duration: TimeInterval = WindowChrome.lightsFadeDuration,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
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
