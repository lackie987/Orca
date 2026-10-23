import AppKit
import WebKit

/// Everything the page can put on screen that is not part of the page itself: JS alert, confirm and
/// prompt panels, permission prompts, new-window attempts and downloads.
extension WebPageController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        present(confirmationAlert(message)) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = confirmationAlert(prompt)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let trusted = origin.host == accessURL?.host || origin.host == "localhost" || origin.host == "127.0.0.1"
        decisionHandler(trusted ? .grant : .deny)
    }

    /// Alert shaped like the ones JS `confirm` and `prompt` expect: OK first, Cancel second.
    private func confirmationAlert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

// MARK: - Downloads

extension WebPageController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        present(panel) { response in
            completionHandler(response == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        NSApp.requestUserAttention(.informationalRequest)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }
}

// MARK: - Presentation

/// What the shell needs from an AppKit dialog to place it inside the window.
protocol PanelPresentable {
    func beginSheet(for window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void)
    func runModal() -> NSApplication.ModalResponse
}

extension NSAlert: PanelPresentable {
    func beginSheet(for window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        beginSheetModal(for: window, completionHandler: completion)
    }
}

extension NSSavePanel: PanelPresentable {
    func beginSheet(for window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        beginSheetModal(for: window, completionHandler: completion)
    }
}

extension WebPageController {
    /// Runs the dialog as a sheet on the page's window, or modally before the window exists.
    func present(
        _ dialog: PanelPresentable,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            dialog.beginSheet(for: window, completion: completion)
        } else {
            completion(dialog.runModal())
        }
    }
}
