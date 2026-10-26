import AppKit

/// The shell's own settings panel: the local service's port, profile and command plus the window's
/// two switches.
///
/// DSH's own settings page owns ⌘, — the page is the settings surface for everything it can see —
/// so this panel sits one modifier further out, on ⌥⌘,. It is the only place the service parameters
/// can be changed, which is what it is for: those are properties of the shell, not of the page.
final class SettingsWindowController: NSWindowController {
    /// Reports whether the edited values require restarting the local service.
    var onSave: ((Bool) -> Void)?

    private static let contentWidth: CGFloat = 592

    private let preferences: Preferences
    private let portField = NSTextField(string: "")
    private let profileField = NSTextField(string: "")
    private let commandField = NSTextField(string: "")
    private let keepAliveCheckbox = NSButton(
        checkboxWithTitle: "Keep the local service running after Orca quits",
        target: nil,
        action: nil
    )
    private let inspectorCheckbox = NSButton(
        checkboxWithTitle: "Enable the Web Inspector",
        target: nil,
        action: nil
    )
    private var originalPort = 0
    private var originalProfile = ""
    private var originalCommand = ""

    init(preferences: Preferences) {
        self.preferences = preferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Orca Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        loadValues()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("Orca does not support nib loading")
    }

    override func showWindow(_ sender: Any?) {
        loadValues()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func build() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        portField.alignment = .right
        portField.placeholderString = "3080"

        let portRow = row(title: "Port", field: portField, fieldWidth: 90, hint: "0 picks a free port automatically")
        let profileRow = row(title: "Profile", field: profileField, fieldWidth: 160, hint: "dsh profile to boot")
        let commandRow = row(
            title: "dsh command",
            field: commandField,
            fieldWidth: 260,
            hint: "PATH name or absolute path"
        )

        keepAliveCheckbox.font = .systemFont(ofSize: 13)
        inspectorCheckbox.font = .systemFont(ofSize: 13)

        let hint = NSTextField(labelWithString: "Changes to the port, profile, or command restart the local service.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [
            portRow,
            profileRow,
            commandRow,
            divider,
            keepAliveCheckbox,
            inspectorCheckbox,
            hint,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: commandRow)
        stack.setCustomSpacing(18, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        for rowView in [portRow, profileRow, commandRow] {
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func row(title: String, field: NSTextField, fieldWidth: CGFloat, hint: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true

        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [label, field, hintLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        return stack
    }

    // MARK: - Values

    private func loadValues() {
        originalPort = preferences.port
        originalProfile = preferences.profile
        originalCommand = preferences.command
        portField.stringValue = String(originalPort)
        profileField.stringValue = originalProfile
        commandField.stringValue = originalCommand
        keepAliveCheckbox.state = preferences.keepServiceRunningAfterQuit ? .on : .off
        inspectorCheckbox.state = preferences.developerExtras ? .on : .off
    }

    // MARK: - Actions

    @objc private func save() {
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (0...65535).contains(port) else {
            presentError("Enter a port between 0 and 65535.")
            return
        }
        let profile = profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty, !command.isEmpty else {
            presentError("The profile and the dsh command cannot be empty.")
            return
        }

        preferences.port = port
        preferences.profile = profile
        preferences.command = command
        preferences.keepServiceRunningAfterQuit = keepAliveCheckbox.state == .on
        preferences.developerExtras = inspectorCheckbox.state == .on

        let needsRestart = port != originalPort || profile != originalProfile || command != originalCommand
        close()
        onSave?(needsRestart)
    }

    @objc private func cancel() {
        loadValues()
        close()
    }

    private func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Check the settings"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
