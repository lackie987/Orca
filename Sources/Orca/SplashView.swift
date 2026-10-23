import AppKit

/// Native startup, restart and failure surface drawn above the web content.
///
/// The surface sits on a frosted-glass backdrop so whatever is behind it — the page during a
/// restart, the empty window during the first launch — stays faintly visible. Above that glass it
/// paints the base colour the web theme published over the bridge, which is what gives the startup
/// screen the same plane as the page; the fill, not the glass, owns the colour so the material's
/// own tint cannot shift it. The icon is rounded with the window's own corner radius so both
/// silhouettes match.
final class SplashView: NSView {
    var onRetry: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// Corner radius the icon shares with the window chrome.
    var iconCornerRadius: CGFloat = WindowMetrics.fallbackCornerRadius {
        didSet { applyIconShape() }
    }

    /// Base colour of the plane the page paints, reported by the theme bridge; nil before any report.
    var baseColor: NSColor? {
        didSet { applyBaseColor() }
    }

    /// Whether a live page sits under the surface, which is the only case where frost is visible.
    ///
    /// Startup runs on an empty window, so the surface can leave the fill fully opaque and land
    /// exactly on the base colour. During a restart the old page is still rendered behind the
    /// surface; there the fill thins out a little so the frost reads as glass rather than paint.
    var showsPageBehind = false {
        didSet { applyBaseColor() }
    }

    /// Default length of the dissolve from the startup surface to the page.
    private static let defaultFadeDuration: TimeInterval = 0.45

    /// Share of the themed fill kept over the glass when a page sits behind it.
    private static let frostedBaseOpacity: Float = 0.86

    private let baseFill = NSView()
    private let backdrop = NSVisualEffectView()
    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Orca")
    private let subtitleLabel = NSTextField(labelWithString: "DeepSeek Harness")
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let logButton = NSButton(title: "Service Log", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Settings…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        showStarting("Preparing the local service…")
    }

    required init?(coder: NSCoder) {
        fatalError("Orca does not support nib loading")
    }

    // MARK: - States

    /// Shows the plain progress screen; the button row stays hidden while the service comes up.
    func showStarting(_ message: String) {
        surface(buttonsHidden: true)
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = message
        detailLabel.stringValue = ""
    }

    func showFailure(_ message: String) {
        surface(buttonsHidden: false)
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = "The local service is unavailable"
        detailLabel.stringValue = message
    }

    func showStopped() {
        surface(buttonsHidden: false)
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = "The local service is stopped"
        detailLabel.stringValue = "Restart it whenever you are ready."
    }

    /// Brings the surface back to full opacity for every state, with the action row on or off.
    private func surface(buttonsHidden: Bool) {
        isHidden = false
        alphaValue = 1
        setButtonsHidden(buttonsHidden)
    }

    /// Fades the surface out.
    ///
    /// The call *is* the hand-over event: the page reports its first painted frame and the shell
    /// dissolves on that report, so nothing here waits for a duration to elapse first. Only the
    /// length of the dissolve lives here, and it collapses to none under Reduce Motion.
    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            isHidden = true
            alphaValue = 1
        }
    }

    /// Dissolve length, honouring the system preference for reduced motion.
    private var fadeDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.defaultFadeDuration
    }

    // MARK: - Layout

    /// Assembles the frosted backdrop, the themed fill on top of it and the centred content column.
    ///
    /// The fill sits above the glass on purpose. A `withinWindow` material does not pass the colour
    /// underneath it through — it lays down its own tinted veil, which dragged `#232136` to a grey
    /// `#25272F` and made the surface disagree with the page. Painting the base over the glass keeps
    /// the pixels on the theme colour and leaves the material responsible only for blur and the
    /// sliver of transparency that shows the page behind it.
    private func build() {
        addBackdrop()
        addBaseFill()
        addContent()
    }

    /// Paints the themed base colour over the glass, at full strength unless a page sits behind.
    private func addBaseFill() {
        baseFill.wantsLayer = true
        Layout.fill(baseFill, in: self)
    }

    /// Fills the surface with within-window vibrancy, which frosts whatever sits behind it.
    private func addBackdrop() {
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        Layout.fill(backdrop, in: self)
    }

    /// Configures the icon, labels, spinner, buttons and pins the column to the centre.
    private func addContent() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 84),
            iconView.heightAnchor.constraint(equalToConstant: 84),
        ])
        applyIconShape()

        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 13)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 380

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = 420

        for button in actionButtons {
            button.bezelStyle = .rounded
            button.controlSize = .regular
        }
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.keyEquivalent = "\r"
        logButton.target = self
        logButton.action = #selector(logPressed)
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(retryButton)
        buttonRow.addArrangedSubview(logButton)
        buttonRow.addArrangedSubview(settingsButton)

        for view in [iconView, titleLabel, subtitleLabel, spinner, statusLabel, detailLabel, buttonRow] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(16, after: iconView)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.setCustomSpacing(14, after: detailLabel)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            statusLabel.widthAnchor.constraint(equalToConstant: 380),
            detailLabel.widthAnchor.constraint(equalToConstant: 420),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        applyTextColors()
    }

    /// Paints the published base colour, sets how much of the glass survives underneath, and
    /// re-inks the copy for the plane's tone.
    private func applyBaseColor() {
        baseFill.layer?.backgroundColor = baseColor?.usingColorSpace(.sRGB)?.cgColor
        // Without a page behind there is nothing worth blurring, and any transparency would only let
        // the material tint through and pull the surface off the theme colour. With a page behind,
        // drop just enough to keep the frost readable while the fill still holds the colour.
        baseFill.layer?.opacity = showsPageBehind ? Self.frostedBaseOpacity : 1
        // The material resolves against the effective appearance, so a dark plane has to put the
        // glass itself in dark mode — otherwise the veil turns milky and the light copy loses contrast.
        backdrop.appearance = isDarkBase ? NSAppearance(named: .darkAqua) : nil
        applyTextColors()
    }

    /// Picks label colours that stay legible on the glass over either a dark or a light base.
    private func applyTextColors() {
        titleLabel.textColor = isDarkBase ? .white : .labelColor
        subtitleLabel.textColor = secondaryTextColor
        statusLabel.textColor = secondaryTextColor
        detailLabel.textColor = tertiaryTextColor
    }

    /// Whether the published base is a dark plane, which flips the copy to light ink.
    private var isDarkBase: Bool {
        guard let baseColor else { return false }
        return ColorHex.isDark(baseColor)
    }

    /// Body copy colour: semantic grey normally, translucent white on a dark plane.
    private var secondaryTextColor: NSColor {
        isDarkBase ? NSColor.white.withAlphaComponent(0.72) : .secondaryLabelColor
    }

    /// Detail copy colour, one step quieter than `secondaryTextColor`.
    private var tertiaryTextColor: NSColor {
        isDarkBase ? NSColor.white.withAlphaComponent(0.5) : .tertiaryLabelColor
    }

    /// Rounds the icon with the window corner radius, using the continuous curve the system uses.
    private func applyIconShape() {
        guard let layer = iconView.layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = iconCornerRadius
        layer.masksToBounds = true
    }

    private func setButtonsHidden(_ hidden: Bool) {
        for button in actionButtons {
            button.isHidden = hidden
        }
    }

    /// Buttons offered on the stopped and failure screens, in display order.
    private var actionButtons: [NSButton] {
        [retryButton, logButton, settingsButton]
    }

    @objc private func retryPressed() {
        onRetry?()
    }

    @objc private func logPressed() {
        onOpenLog?()
    }

    @objc private func settingsPressed() {
        onOpenSettings?()
    }
}
