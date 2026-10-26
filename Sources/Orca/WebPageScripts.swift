import WebKit

/// Every script the shell injects into the page, and the order it runs in.
///
/// The scripts are the page side of the native bridges: they define `window.__DSH_DIRECTORY_PICKER__`,
/// `window.__ORCA_TITLEBAR__` and `window.__ORCA_PALETTE__`, mirror the theme back to the shell, and
/// report the events the native side waits for (drag-band height and the first painted frame).
/// The literals live in one file per concern — `WebPageScriptsDesktop` for the desktop-runtime
/// illusion, `WebPageScriptsChrome` for the window and the theme, `WebPageScriptsPage` for the page
/// bridges — while this file owns only the order they run in.
enum WebPageScripts {
    /// Adds every script to the page, in the order the web view should run it.
    static func install(on userContentController: WKUserContentController, bootBackground: String) {
        for script in userScripts(bootBackground: bootBackground) {
            userContentController.addUserScript(script)
        }
    }

    /// Everything the shell injects, in the order the web view should run it.
    private static func userScripts(bootBackground: String) -> [WKUserScript] {
        [
            // First, so the page boots as a desktop shell and the shortcut service sees it.
            WKUserScript(source: desktop, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            // Then the very first frame already carries the theme instead of the app's default.
            WKUserScript(source: bootBackgroundScript(bootBackground), injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: console, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: directoryPicker, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: titleBar, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: palette, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: appIcon, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: dragZone, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: theme, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: pagePainted, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: inputCompletion, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
        ]
    }

    /// Paints the page's first frame with the theme's base colour.
    ///
    /// The web app's own stylesheet travels with the client modules, i.e. arrives after the first
    /// paint; without this the hand-over from the startup surface flashes the page's default dark
    /// grey. The rule is removed as soon as the theme publishes its base (the shell calls that), and
    /// by a timeout if no theme ever reports.
    private static func bootBackgroundScript(_ hex: String) -> String {
        let safe = ColorHex.color(hex).flatMap(ColorHex.string) ?? "#191724"
        let scheme = (ColorHex.color(safe).map(ColorHex.isDark) ?? true) ? "dark" : "light"
        return #"""
        (function () {
          if (document.getElementById('orca-boot-bg')) { return; }
          var style = document.createElement('style');
          style.id = 'orca-boot-bg';
          style.textContent = 'html,body,#root,#app{background-color:\#(safe) !important;color-scheme:\#(scheme);}';
          (document.head || document.documentElement).appendChild(style);
          window.setTimeout(function () {
            var stale = document.getElementById('orca-boot-bg');
            if (stale) { stale.remove(); }
          }, 3000);
        })();
        """#
    }
}
