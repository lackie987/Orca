import AppKit
import WebKit

/// The two bridges the page uses to dress the window: the traffic-light preset its settings row
/// writes, and the theme base colour it publishes for the startup surface.
///
/// Both are thin settings bridges — the shell owns the value, the page only asks for it and posts a
/// new one — so they live together, one file apart from the icon and desktop bridges.
extension WebPageController {
    /// Handles `get`/`set` requests from the `dsh-orca-titlebar` plugin bridge.
    func handleTitleBarMessage(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
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
    func handlePaletteMessage(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
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
}
