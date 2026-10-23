import AppKit
import WebKit

/// Message channels the page talks through: one-way notifications (theme, drag band, console,
/// first painted frame) and the two-way bridges behind `__ORCA_TITLEBAR__`, `__ORCA_PALETTE__` and
/// the directory picker.
extension WebPageController {
    /// Wires the message channels; both groups go through weak wrappers so the web view can be freed.
    func installBridges(on userContentController: WKUserContentController) {
        for name in ["themeSource", "titleBar", "diagnostics", "orcaPagePainted"] {
            userContentController.add(WeakScriptMessageHandler(target: self), name: name)
        }
        for name in ["directoryPicker", "orcaTitleBar", "orcaPalette"] {
            userContentController.addScriptMessageHandler(
                WeakReplyScriptMessageHandler(target: self),
                contentWorld: .page,
                name: name
            )
        }
    }
}

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
                WebDiagnostics.append(line)
            }
        case "orcaPagePainted":
            onPagePainted?()
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
        switch message.name {
        case "orcaTitleBar":
            handleTitleBarMessage(message, replyHandler: replyHandler)
        case "orcaPalette":
            handlePaletteMessage(message, replyHandler: replyHandler)
        case "directoryPicker":
            handleDirectoryPicker(replyHandler: replyHandler)
        default:
            replyHandler(nil, "Unsupported Orca bridge: \(message.name)")
        }
    }

    /// Handles `get`/`set` requests from the `dsh-orca-titlebar` plugin bridge.
    private func handleTitleBarMessage(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        handleSettingBridge(
            message,
            name: "orcaTitleBar",
            field: "mode",
            current: { [weak self] in self?.preferences.titleBarMode ?? "" },
            normalize: { TitleBarMode(rawValue: $0) == nil ? nil : $0 },
            store: { [weak self] mode in
                guard let self else { return }
                preferences.titleBarMode = mode
                onTitleBarModeChange?(mode)
            },
            replyHandler: replyHandler
        )
    }

    /// Handles `get`/`set` requests from the `__ORCA_PALETTE__` theme bridge.
    ///
    /// Only `#rrggbb` values are accepted; anything else is answered with the colour already stored.
    private func handlePaletteMessage(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        handleSettingBridge(
            message,
            name: "orcaPalette",
            field: "base",
            current: { [weak self] in self?.preferences.splashBaseColor ?? "" },
            normalize: { raw in ColorHex.color(raw).flatMap(ColorHex.string) },
            store: { [weak self] hex in
                guard let self else { return }
                preferences.splashBaseColor = hex
                onPaletteBase?(hex)
            },
            replyHandler: replyHandler
        )
    }

    /// Asks the user for a workspace folder and answers the page with its path, or nil on cancel.
    private func handleDirectoryPicker(replyHandler: @escaping (Any?, String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                replyHandler(nil, "Orca is shutting down")
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose a workspace folder"
            self.present(panel) { response in
                guard response == .OK, let url = panel.url else {
                    replyHandler(nil, nil)
                    return
                }
                replyHandler(url.path, nil)
            }
        }
    }

    /// Shared shape of the plugin bridges.
    ///
    /// `get` answers with the value currently stored, `set` validates the posted field and answers
    /// with the value it accepted; a rejected payload is answered with the stored value so the page
    /// can tell the two apart instead of assuming its write landed.
    private func handleSettingBridge(
        _ message: WKScriptMessage,
        name: String,
        field: String,
        current: @escaping () -> String,
        normalize: @escaping (String) -> String?,
        store: @escaping (String) -> Void,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let payload = message.body as? [String: Any],
              let kind = payload["kind"] as? String else {
            replyHandler(nil, "Malformed \(name) message")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard self != nil else {
                replyHandler(nil, "Orca is shutting down")
                return
            }
            switch kind {
            case "get":
                replyHandler(current(), nil)
            case "set":
                guard let raw = payload[field] as? String, let value = normalize(raw) else {
                    replyHandler(current(), nil)
                    return
                }
                store(value)
                replyHandler(value, nil)
            default:
                replyHandler(nil, "Unknown \(name) kind: \(kind)")
            }
        }
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
