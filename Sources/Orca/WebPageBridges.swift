import AppKit
import UniformTypeIdentifiers
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
        for name in ["directoryPicker", "orcaTitleBar", "orcaPalette", "orcaAppIcon", "orcaDesktop"] {
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
        case "orcaAppIcon":
            handleAppIconMessage(message, replyHandler: replyHandler)
        case "orcaDesktop":
            handleDesktopMessage(message, replyHandler: replyHandler)
        default:
            replyHandler(nil, "Unsupported Orca bridge: \(message.name)")
        }
    }

    /// Shared shape of the plugin bridges.
    ///
    /// `get` answers with the value currently stored, `set` validates the posted field and answers
    /// with the value it accepted; a rejected payload is answered with the stored value so the page
    /// can tell the two apart instead of assuming its write landed.
    func handleSettingBridge(
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
