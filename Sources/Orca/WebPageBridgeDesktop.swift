import AppKit
import WebKit

/// The bridges that treat the page as a desktop application: the workspace directory picker, the
/// keybinding and device-info channel the shortcut service talks through, and closing the window.
///
/// Everything here is a request/answer the page awaits, so each handler funnels through the same
/// reply contract: real value on success, `NSNull` when an answer is legitimately empty, and a
/// message only when something actually failed.
extension WebPageController {
    /// Asks the user for a workspace folder and answers the page with its path, or nil on cancel.
    func handleDirectoryPicker(replyHandler: @escaping (Any?, String?) -> Void) {
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
                    // A cancelled/empty selection must resolve to `null` in JS (not `undefined`):
                    // WebKit serialises a `nil` reply as `undefined`, while `NSNull` becomes `null`.
                    // The web client treats `null` as "no selection" and routes to onCancel, but
                    // `undefined` leaks into createWorkspace({ path }) and trips the strict gateway
                    // boundary (`wire field "request" failed boundary validation`).
                    replyHandler(NSNull(), nil)
                    return
                }
                replyHandler(url.path, nil)
            }
        }
    }

    /// Handles the desktop-shell bridge: keybinding persistence, device info, and window close.
    ///
    /// The keybinding document is opaque JSON: the page owns the revision/edit protocol, while this
    /// side only reads and writes the file atomically.
    func handleDesktopMessage(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let payload = message.body as? [String: Any],
              let kind = payload["kind"] as? String else {
            replyHandler(nil, "Malformed orcaDesktop message")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                replyHandler(nil, "Orca is shutting down")
                return
            }
            switch kind {
            case "shortcuts.read":
                guard FileManager.default.fileExists(atPath: AppPaths.keybindings.path) else {
                    replyHandler(NSNull(), nil)
                    return
                }
                do {
                    let data = try Data(contentsOf: AppPaths.keybindings)
                    replyHandler(String(data: data, encoding: .utf8) ?? "", nil)
                } catch {
                    replyHandler(nil, "Could not read keybindings: \(error.localizedDescription)")
                }
            case "shortcuts.write":
                guard let raw = payload["raw"] as? String else {
                    replyHandler(nil, "Missing keybinding document")
                    return
                }
                do {
                    try Data(raw.utf8).write(to: AppPaths.keybindings, options: .atomic)
                    replyHandler(true, nil)
                } catch {
                    replyHandler(nil, "Could not write keybindings: \(error.localizedDescription)")
                }
            case "deviceInfo":
                replyHandler(Self.deviceSummary, nil)
            case "closeWindow":
                self.onCloseWindow?()
                replyHandler(nil, nil)
            default:
                replyHandler(nil, "Unknown orcaDesktop kind: \(kind)")
            }
        }
    }

    /// Compact device description for the account contact form; no identifiers or secrets.
    private static var deviceSummary: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(architecture))"
    }
}
