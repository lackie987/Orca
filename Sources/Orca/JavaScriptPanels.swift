import AppKit

/// The panels `alert()`, `confirm()` and `prompt()` map to, built in one place.
///
/// Every web view the shell owns — the app window and a sign-in popup — has to answer these, and the
/// panels should read the same in both. Only where they are presented differs: a sheet on the page's
/// window here, a sheet on the popup's there.
enum JavaScriptPanels {
    /// `alert()`: one button, nothing to decide.
    static func alert(_ message: String) -> NSAlert {
        panel(message, buttons: ["OK"])
    }

    /// `confirm()` and `prompt()`: OK first, Cancel second, which is the order JS expects.
    static func confirmation(_ message: String) -> NSAlert {
        panel(message, buttons: ["OK", "Cancel"])
    }

    /// Builds the alert with its buttons in the order given.
    private static func panel(_ message: String, buttons: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }
}
