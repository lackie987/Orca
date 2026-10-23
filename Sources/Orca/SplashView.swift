import AppKit

/// Native startup and failure surface drawn above the web content.
final class SplashView: NSView {
    var onRetry: (() -> Void)?
    var onOpenLog: (() -> Void)?
    var onOpenSettings: (() -> Void)?

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

    func showStarting(_ message: String) {
        isHidden = false
        alphaValue = 1
        spinner.isHidden = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = ""
        setButtonsHidden(true)
    }

    func showFailure(_ message: String) {
        isHidden = false
        alphaValue = 1
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = "The local service is unavailable"
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = message
        setButtonsHidden(false)
    }

    func showStopped() {
        isHidden = false
        alphaValue = 1
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = "The local service is stopped"
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.stringValue = "Restart it whenever you are ready."
        setButtonsHidden(false)
    }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            isHidden = true
            alphaValue = 1
        }
    }

    // MARK: - Layout

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 84),
            iconView.heightAnchor.constraint(equalToConstant: 84),
        ])

        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 380

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = 420

        for button in [retryButton, logButton, settingsButton] {
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
    }

    private func setButtonsHidden(_ hidden: Bool) {
        for button in [retryButton, logButton, settingsButton] {
            button.isHidden = hidden
        }
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
