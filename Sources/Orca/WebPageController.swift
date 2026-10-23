import AppKit
import WebKit

/// Hosts the DSH web UI: navigation policy, native bridges, downloads, dialogs and zoom.
final class WebPageController: NSObject {
    let webView: WKWebView

    /// Theme source published by the web UI (`system`, `light` or `dark`).
    var onThemeSource: ((String) -> Void)?

    private let preferences: Preferences
    private var accessURL: URL?

    init(preferences: Preferences) {
        self.preferences = preferences

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController

        webView = DraggableWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        userContentController.addUserScript(
            WKUserScript(source: Self.consoleBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        userContentController.addUserScript(
            WKUserScript(source: Self.documentStartScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        userContentController.addUserScript(
            WKUserScript(source: Self.dragZoneScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        userContentController.addUserScript(
            WKUserScript(source: Self.documentEndScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        userContentController.add(WeakScriptMessageHandler(target: self), name: "themeSource")
        userContentController.add(WeakScriptMessageHandler(target: self), name: "titleBar")
        userContentController.add(WeakScriptMessageHandler(target: self), name: "diagnostics")
        userContentController.addScriptMessageHandler(
            WeakReplyScriptMessageHandler(target: self),
            contentWorld: .page,
            name: "directoryPicker"
        )

        applyPreferences()
    }

    /// Applies settings that can change while the window is open.
    func applyPreferences() {
        setZoom(CGFloat(preferences.pageZoom), persist: false)
        if #available(macOS 13.3, *) {
            webView.isInspectable = preferences.developerExtras
        }
    }

    /// Loads the tokenized access URL printed by the service.
    func load(_ url: URL) {
        accessURL = url
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    func reload() {
        webView.reload()
    }

    func reloadFromOrigin() {
        webView.reloadFromOrigin()
    }

    func zoomIn() {
        setZoom(webView.pageZoom * 1.1, persist: true)
    }

    func zoomOut() {
        setZoom(webView.pageZoom / 1.1, persist: true)
    }

    func resetZoom() {
        setZoom(1, persist: true)
    }

    /// Mirrors the native full-screen state onto `<html data-fullscreen>` so the page reclaims the title-bar clearance.
    func applyFullscreen(_ isFullscreen: Bool) {
        let script = isFullscreen
            ? "document.documentElement.dataset.fullscreen = 'true'"
            : "delete document.documentElement.dataset.fullscreen"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func setZoom(_ value: CGFloat, persist: Bool) {
        let clamped = min(max(value, 0.5), 3)
        webView.pageZoom = clamped
        if persist {
            preferences.pageZoom = Double(clamped)
        }
    }

    private func isInternal(_ url: URL) -> Bool {
        guard let accessURL else { return false }
        return url.host == accessURL.host && effectivePort(url) == effectivePort(accessURL)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme == "https" ? 443 : 80)
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    // MARK: - Diagnostics

    private static let diagnosticQueue = DispatchQueue(label: "com.xu.orca.diagnostics")
    private static var diagnosticLog: URL { AppPaths.logs.appendingPathComponent("web.log") }

    /// Appends one browser-side console line to the diagnostic log.
    private static func appendDiagnostic(_ line: String) {
        diagnosticQueue.async {
            let url = diagnosticLog
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let entry = "[\(stamp)] \(line)\n"
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        }
    }

    // MARK: - Injected scripts

    /// Forwards console errors and uncaught exceptions to the native diagnostic log.
    private static let consoleBridgeScript = #"""
    (function () {
      function describe(value) {
        try {
          if (typeof value === 'string') { return value; }
          if (value instanceof Error) {
            return (value.name || 'Error') + ': ' + (value.message || '') + '\n' + (value.stack || '');
          }
          return JSON.stringify(value);
        } catch (error) {
          return String(value);
        }
      }
      function post(level, values) {
        try {
          var text = Array.prototype.map.call(values, describe).join(' ');
          window.webkit.messageHandlers.diagnostics.postMessage(level + ': ' + text);
        } catch (error) {}
      }
      ['error', 'warn'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          post(level, arguments);
          original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (event) {
        post('window.error', [event.message + ' (' + event.filename + ':' + event.lineno + ')']);
      });
      window.addEventListener('unhandledrejection', function (event) {
        post('unhandledrejection', [event.reason]);
      });
    })();
    """#

    /// Exposes the native folder picker where the web UI asks for a workspace directory.
    private static let documentStartScript = #"""
    (function () {
      if (window.__DSH_DIRECTORY_PICKER__ !== undefined) { return; }
      try {
        Object.defineProperty(window, '__DSH_DIRECTORY_PICKER__', {
          configurable: true,
          value: {
            pick: function () {
              return window.webkit.messageHandlers.directoryPicker.postMessage({});
            }
          }
        });
      } catch (error) {}
    })();
    """#

    /// Reports the page header height so the hidden title bar keeps a matching drag band.
    private static let dragZoneScript = #"""
    (function () {
      function report() {
        var height = 0;
        var headers = document.querySelectorAll('header');
        for (var index = 0; index < headers.length; index += 1) {
          var rect = headers[index].getBoundingClientRect();
          if (rect.top <= 2 && rect.height >= 24 && rect.height <= 160 && rect.width >= 400) {
            height = Math.round(rect.height);
            break;
          }
        }
        try {
          window.webkit.messageHandlers.titleBar.postMessage({ height: height });
        } catch (error) {}
      }

      var timer = null;
      function schedule() {
        if (timer !== null) { return; }
        timer = window.setTimeout(function () {
          timer = null;
          report();
        }, 150);
      }

      function start() {
        report();
        window.setTimeout(report, 500);
        window.setTimeout(report, 1500);
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        window.addEventListener('resize', schedule);
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#

    /// Mirrors the web UI theme source so native chrome follows the page palette.
    private static let documentEndScript = #"""
    (function () {
      function sendTheme() {
        try {
          var source = document.documentElement.getAttribute('data-ds-theme-source') || 'system';
          window.webkit.messageHandlers.themeSource.postMessage(source);
        } catch (error) {}
      }
      function start() {
        sendTheme();
        new MutationObserver(sendTheme).observe(document.documentElement, {
          attributes: true,
          attributeFilter: ['data-ds-theme-source']
        });
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#

}

// MARK: - Navigation

extension WebPageController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if isInternal(url) && navigationAction.targetFrame != nil {
            decisionHandler(.allow)
        } else if isInternal(url) && navigationAction.navigationType == .other {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let fullscreen = webView.window?.styleMask.contains(.fullScreen) ?? false
        applyFullscreen(fullscreen)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - Script messages

extension WebPageController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "themeSource":
            if let source = message.body as? String {
                onThemeSource?(source)
            }
        case "titleBar":
            guard let payload = message.body as? [String: Any],
                  let height = (payload["height"] as? NSNumber)?.doubleValue,
                  height >= 24
            else { return }
            (webView as? DraggableWebView)?.dragZoneHeight = CGFloat(height)
        case "diagnostics":
            if let line = message.body as? String {
                Self.appendDiagnostic(line)
            }
        default:
            break
        }
    }
}

extension WebPageController: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.name == "directoryPicker" else {
            replyHandler(nil, "Unsupported Orca bridge: \(message.name)")
            return
        }
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose a workspace folder"
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let url = panel.url {
                    replyHandler(url.path, nil)
                } else {
                    replyHandler(nil, nil)
                }
            }
            if let window = self.webView.window {
                panel.beginSheetModal(for: window, completionHandler: complete)
            } else {
                complete(panel.runModal())
            }
        }
    }
}

// MARK: - Dialogs and new windows

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
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
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
        let complete: (NSApplication.ModalResponse) -> Void = { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            complete(panel.runModal())
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

// MARK: - Weak bridges

/// Breaks the `WKUserContentController` → handler → web view retain cycle for plain messages.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Breaks the same cycle for message-with-reply bridges.
private final class WeakReplyScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var target: WKScriptMessageHandlerWithReply?

    init(target: WKScriptMessageHandlerWithReply) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let target else {
            replyHandler(nil, "Orca is shutting down")
            return
        }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}
