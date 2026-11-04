import AppKit

/// The shell's own settings panel: the local service's port, profile and command plus the window's
/// two switches and the shell language.
///
/// DSH's own settings page owns ⌘, — the page is the settings surface for everything it can see —
/// so this panel sits one modifier further out, on ⌥⌘,. It is the only place the service parameters
/// can be changed, which is what it is for: those are properties of the shell, not of the page.
///
/// Every label is built from `ShellCopy`, so a language switch rebuilds the panel instead of
/// mutating each field in place: the two-column alignment belongs to the copy's length, not to the
/// field.
final class SettingsWindowController: NSWindowController {
    /// Reports whether the edited values require restarting the local service.
    var onSave: ((Bool) -> Void)?
    /// Called after the shell language changed, so the menu bar can be rebuilt in the new one.
    var onLanguageChange: (() -> Void)?

    private static let contentWidth: CGFloat = 592
    private static let contentInset: CGFloat = 24
    /// Content starts below the transparent titlebar and its traffic lights.
    private static let titlebarInset: CGFloat = 48
    private static let brandMarkSide: CGFloat = 36
    /// Width of the right-aligned column every field label shares.
    private static let labelColumnWidth: CGFloat = 96
    private static let switchSpacing: CGFloat = 4
    private static let sectionSpacing: CGFloat = 16
    private static let footerSpacing: CGFloat = 18

    private let preferences: Preferences
    private let contentView = NSView()
    private let portField = NSTextField(string: "")
    private let profileField = NSTextField(string: "")
    private let commandField = NSTextField(string: "")
    private let keepAliveCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let inputAssistanceCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var originalPort = 0
    private var originalProfile = ""
    private var originalCommand = ""
    private var originalLanguage = ShellLanguage.zh

    private var copy: ShellCopy { preferences.copy }

    init(preferences: Preferences) {
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        loadValues()
        applyTheme()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("Orca does not support nib loading")
    }

    override func showWindow(_ sender: Any?) {
        loadValues()
        applyTheme()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    /// Assembles the whole panel, top to bottom.
    private func build() {
        guard let window else { return }
        window.contentView = contentView
        window.title = copy.settings.title

        let header = makeHeader()
        let serviceRows = makeServiceRows()
        let switches = makeSwitches()
        let language = makeLanguageRow()
        let footer = makeHint(copy.settings.restartHint)
        let buttons = makeButtons()

        let order: [NSView] = [header]
            + serviceRows
            + [makeDivider()]
            + switches
            + [makeDivider(), language, footer, buttons]
        let stack = verticalStack(order)
        stack.setCustomSpacing(Self.sectionSpacing, after: header)
        if let lastRow = serviceRows.last {
            stack.setCustomSpacing(Self.sectionSpacing, after: lastRow)
        }
        stack.setCustomSpacing(Self.switchSpacing, after: switches[1])
        stack.setCustomSpacing(Self.footerSpacing, after: footer)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.contentInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.titlebarInset),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor,
                constant: -Self.contentInset
            ),
        ])
        for view in [header, language, footer, buttons] + serviceRows {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// The vertical column every section is added to.
    private func verticalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Brand row shared with the startup surface: the transparent character mark, then the shell name.
    private func makeHeader() -> NSStackView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.brandMarkSide),
            icon.heightAnchor.constraint(equalToConstant: Self.brandMarkSide),
        ])
        if let mark = AppIcon.startupMark() {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            icon.image = IconProcessor.rounded(mark, size: Self.brandMarkSide * scale) ?? mark
        } else {
            icon.image = AppIcon.startupImage()
        }

        let title = NSTextField(labelWithString: "Orca")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "DeepSeek Harness")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        return header
    }

    /// The three service parameters, in the order the shell reads them.
    private func makeServiceRows() -> [NSStackView] {
        portField.alignment = .right
        portField.placeholderString = "3080"
        return [
            fieldRow(title: copy.settings.port, field: portField, fieldWidth: 90, hint: copy.settings.portHint),
            fieldRow(title: copy.settings.profile, field: profileField, fieldWidth: 160, hint: copy.settings.profileHint),
            fieldRow(title: copy.settings.command, field: commandField, fieldWidth: 260, hint: copy.settings.commandHint),
        ]
    }

    /// The two switches, followed by the sentence explaining what the second one covers.
    private func makeSwitches() -> [NSView] {
        keepAliveCheckbox.title = copy.settings.keepAlive
        inputAssistanceCheckbox.title = copy.settings.inputAssistance
        for checkbox in [keepAliveCheckbox, inputAssistanceCheckbox] {
            checkbox.font = .systemFont(ofSize: 13)
        }
        return [keepAliveCheckbox, inputAssistanceCheckbox, makeHint(copy.settings.inputAssistanceHint)]
    }

    /// The only choice that does not reach the service: it rebuilds the shell's own copy.
    private func makeLanguageRow() -> NSStackView {
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: ShellLanguage.allCases.map(\.displayName))
        languagePopup.font = .systemFont(ofSize: 13)

        let stack = NSStackView(views: [fieldLabel(copy.settings.language), languagePopup, makeHint(copy.settings.languageHint)])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        return stack
    }

    /// Cancel on the left of Save, both pinned to the panel's trailing edge.
    private func makeButtons() -> NSStackView {
        let cancelButton = NSButton(title: copy.common.cancel, target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: copy.settings.save, target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        return buttons
    }

    private func makeDivider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        return divider
    }

    /// A settings hint: small, tertiary, wrapping to the panel's width.
    private func makeHint(_ text: String) -> NSTextField {
        let hint = NSTextField(labelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = Self.contentWidth
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return hint
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        return label
    }

    private func fieldRow(
        title: String,
        field: NSTextField,
        fieldWidth: CGFloat,
        hint: String
    ) -> NSStackView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let stack = NSStackView(views: [fieldLabel(title), field, makeHint(hint)])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        return stack
    }

    /// Gives the panel the page's base plane and lets AppKit resolve its controls against that tone.
    private func applyTheme() {
        guard let window else { return }
        let base = ColorHex.color(preferences.splashBaseColor)
        let background = base ?? .windowBackgroundColor
        window.backgroundColor = background
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = background.usingColorSpace(.sRGB)?.cgColor
        if let base {
            window.appearance = NSAppearance(named: ColorHex.isDark(base) ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
    }

    // MARK: - Values

    private func loadValues() {
        originalPort = preferences.port
        originalProfile = preferences.profile
        originalCommand = preferences.command
        originalLanguage = preferences.language
        portField.stringValue = String(originalPort)
        profileField.stringValue = originalProfile
        commandField.stringValue = originalCommand
        keepAliveCheckbox.state = preferences.keepServiceRunningAfterQuit ? .on : .off
        inputAssistanceCheckbox.state = preferences.disableInputCompletion ? .on : .off
        if let index = ShellLanguage.allCases.firstIndex(of: originalLanguage) {
            languagePopup.selectItem(at: index)
        }
    }

    /// Replaces the panel's content with the copy for the current language.
    private func rebuild() {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        // The fields outlive the layout, so their width constraints have to go with the old rows;
        // adding a second identical set on every rebuild only piles up dead constraints.
        for field in [portField, profileField, commandField] {
            field.removeConstraints(field.constraints)
        }
        build()
        loadValues()
        applyTheme()
    }

    // MARK: - Actions

    @objc private func save() {
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (0...65535).contains(port) else {
            presentError(copy.settings.portError)
            return
        }
        let profile = profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty, !command.isEmpty else {
            presentError(copy.settings.emptyError)
            return
        }

        preferences.port = port
        preferences.profile = profile
        preferences.command = command
        preferences.keepServiceRunningAfterQuit = keepAliveCheckbox.state == .on
        preferences.disableInputCompletion = inputAssistanceCheckbox.state == .on
        applyLanguage()

        let needsRestart = port != originalPort || profile != originalProfile || command != originalCommand
        close()
        onSave?(needsRestart)
    }

    @objc private func cancel() {
        loadValues()
        close()
    }

    /// Stores a new language, then rebuilds this panel and the menu bar in it.
    private func applyLanguage() {
        let selected = selectedLanguage()
        guard selected != originalLanguage else { return }
        preferences.language = selected
        originalLanguage = selected
        rebuild()
        onLanguageChange?()
    }

    /// The language picked in the popup, which sits in `allCases` order.
    private func selectedLanguage() -> ShellLanguage {
        let index = languagePopup.indexOfSelectedItem
        guard ShellLanguage.allCases.indices.contains(index) else { return preferences.language }
        return ShellLanguage.allCases[index]
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = copy.settings.invalidTitle
        alert.informativeText = message
        alert.addButton(withTitle: copy.common.ok)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
