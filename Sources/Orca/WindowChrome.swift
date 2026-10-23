import AppKit

/// Window chrome driven by the `dsh-orca-titlebar` plugin: title visibility, the traffic lights and
/// the hover band that reveals them.
///
/// `hover` (the default) keeps the native chrome transparent with no visible title and reveals the
/// real traffic lights through a transparent top band when the pointer enters it — the Helium-style
/// hover title bar, drawn natively rather than as a web overlay.
final class WindowChrome {
    private let window: NSWindow
    private var hoverBand: HoverBandView?
    private var hideLightsWorkItem: DispatchWorkItem?

    init(window: NSWindow) {
        self.window = window
    }

    /// Applies the preset the plugin selected, or the persisted one when it has not spoken yet.
    func apply(_ raw: String) {
        switch TitleBarMode.parse(raw) {
        case .hidden:
            setChrome(transparent: true, lightsHidden: true, topInset: 0)
            disableHover()
        case .hover:
            setChrome(transparent: true, lightsHidden: true, topInset: 0)
            enableHover()
        case .lightsOnly:
            setChrome(transparent: true, lightsHidden: false, topInset: 44)
            disableHover()
        case .shown:
            setChrome(transparent: false, lightsHidden: false, topInset: 0)
            disableHover()
        }
    }

    /// Sets window chrome and the top safe-area inset used by the `lightsOnly` preset.
    private func setChrome(transparent: Bool, lightsHidden: Bool, topInset: CGFloat) {
        window.titleVisibility = transparent ? .hidden : .visible
        window.titlebarAppearsTransparent = transparent
        window.titlebarSeparatorStyle = transparent ? .none : .automatic
        for button in trafficLights {
            button.isHidden = lightsHidden
        }
        window.contentView?.additionalSafeAreaInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
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
                band.heightAnchor.constraint(equalToConstant: 28),
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
