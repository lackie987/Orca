import Foundation
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
    static func install(on userContentController: WKUserContentController, bootBackground: String, bootFont: String?) {
        for script in userScripts(bootBackground: bootBackground, bootFont: bootFont) {
            userContentController.addUserScript(script)
        }
    }

    /// Everything the shell injects, in the order the web view should run it.
    private static func userScripts(bootBackground: String, bootFont: String?) -> [WKUserScript] {
        [
            // First, so the page boots as a desktop shell and the shortcut service sees it.
            WKUserScript(source: desktop, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            // Then the very first frame already carries the theme instead of the app's default.
            WKUserScript(source: bootBackgroundScript(bootBackground, bootFont: bootFont), injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: appVersionScript, injectionTime: .atDocumentStart, forMainFrameOnly: true),
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

    /// The Orca bundle version, published for the settings UI that shows the shell version.
    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
    }

    /// Exposes the shell version at document start; absent in a plain browser.
    private static var appVersionScript: String {
        let version = appVersion
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "(function(){try{Object.defineProperty(window,'__ORCA_APP_VERSION__',{configurable:true,value:\"\(version)\"});}catch(e){}})();"
    }

    /// Paints the page's first frame with the theme's base colour.
    ///
    /// The web app's own stylesheet travels with the client modules, i.e. arrives after the first
    /// paint; without this the hand-over from the startup surface flashes the page's default dark
    /// grey. The rule is removed as soon as the theme publishes its base (the shell calls that), and
    /// by a timeout if no theme ever reports.
    private static func bootBackgroundScript(_ hex: String, bootFont: String?) -> String {
        let safe = ColorHex.color(hex).flatMap(ColorHex.string) ?? "#191724"
        let dark = ColorHex.color(safe).map(ColorHex.isDark) ?? true
        let scheme = dark ? "dark" : "light"
        let fg = dark ? "#e0def4" : "#575279"
        let fgSecondary = dark ? "#908caa" : "#797593"
        let fgTertiary = dark ? "#6e6a86" : "#9893a5"
        let border = dark ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.12)"
        let font = (bootFont ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let fontRule = font.isEmpty ? "" : "'[data-dsh-boot]{font-family:\(font) !important;}',"
        return #"""
        (function () {
          if (document.getElementById('orca-boot-bg')) { return; }
          var style = document.createElement('style');
          style.id = 'orca-boot-bg';
          style.textContent = [
            'html,body,#root,#app,[data-dsh-boot]{background-color:\#(safe) !important;color-scheme:\#(scheme);}',
            '[data-dsh-boot]{--dsw-alias-bg-base:\#(safe) !important;--dsh-boot-bg:\#(safe);',
            '--dsw-alias-label-primary:\#(fg) !important;--dsw-alias-label-secondary:\#(fgSecondary) !important;',
            '--dsw-alias-label-tertiary:\#(fgTertiary) !important;--dsw-alias-border-l2:\#(border) !important;',
            '--dsh-boot-label-primary:\#(fg);--dsh-boot-label-secondary:\#(fgSecondary);',
            '--dsh-boot-label-tertiary:\#(fgTertiary);--dsh-boot-border:\#(border);}',
            \#(fontRule)
          ].join('');
          (document.head || document.documentElement).appendChild(style);
          window.setTimeout(function () {
            var stale = document.getElementById('orca-boot-bg');
            if (stale) { stale.remove(); }
          }, 12000);
        })();
        """#
    }
}
