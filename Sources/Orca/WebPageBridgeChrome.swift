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
                // Startup can report the system scheme for a frame before the saved light/dark
                // theme lands; accepting it would repaint the startup surface and poison the next
                // launch's persisted base.
                guard self.paletteMatchesThemeSource(hex) else { return }
                // `applySplashBase` is the only writer of the stored plane: it has to see the
                // previous value to tell whether the base actually moved, and a theme-following
                // template icon is only re-derived on a real move. Writing here first made that
                // comparison always false, so the Dock kept the previous theme's colour until the
                // icon settings were touched again.
                self.applyPaletteBase(hex)
                // The theme is painting now; drop the boot-only override so the page's own
                // token layer owns the background again.
                webView.evaluateJavaScript(
                    "var node = document.getElementById('orca-boot-bg'); if (node) { node.remove(); }",
                    completionHandler: nil
                )
            },
            replyHandler: replyHandler
        )
    }

    /// Whether a palette report may repaint the startup plane yet.
    ///
    /// Before the page is revealed, the host can report the system scheme while its saved theme is
    /// still loading. Only a plane that agrees with the known theme source — or, before a source is
    /// known, with the persisted plane — is accepted then. Once the page owns the window, its
    /// palette is authoritative and every report is accepted.
    private func paletteMatchesThemeSource(_ hex: String) -> Bool {
        // A first painted frame is not the hand-over: the startup surface is still up, and the boot
        // stream can keep reporting the system scheme until the saved theme settles. Trust the
        // palette only once the page actually owns the window, or the surface flashes that plane.
        if isRevealed { return true }
        guard let color = ColorHex.color(hex) else { return false }
        let dark = ColorHex.isDark(color)
        switch preferences.themeSource {
        case "light":
            return !dark
        case "dark":
            return dark
        case "system":
            return dark == ThemeColor.systemIsDark
        default:
            guard let stored = ColorHex.color(preferences.splashBaseColor) else { return true }
            return dark == ColorHex.isDark(stored)
        }
    }
}
