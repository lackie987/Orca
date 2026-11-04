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
        guard let url = navigationAction.request.url else {
            return openPopup(with: configuration)
        }
        switch url.scheme?.lowercased() ?? "" {
        case "", "about", "data", "blob":
            // A popup that is still blank is a work tab: the page opens it, then navigates it
            // itself — DSH's sign-in does exactly that, so the shell has to give it a window.
            return openPopup(with: configuration)
        case "http", "https":
            // A popup with a real destination is a link the page wants outside: the browser has it.
            NSWorkspace.shared.open(url)
            return nil
        default:
            return nil
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        present(JavaScriptPanels.alert(message)) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        present(JavaScriptPanels.confirmation(message)) { response in
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
        let alert = JavaScriptPanels.confirmation(prompt)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        // Keep the prompt field free of the system auto-completion "补全提示".
        field.isAutomaticTextCompletionEnabled = false
        alert.accessoryView = field
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// `<input type="file">` needs this delegate or the click is silently dropped; the page's own
    /// drop targets (the composer, the wallpaper row) never reach it.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        present(panel) { response in
            completionHandler(response == .OK ? panel.urls : nil)
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
        alert.messageText = Preferences.shared.copy.alert.downloadFailed
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: Preferences.shared.copy.common.ok)
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
