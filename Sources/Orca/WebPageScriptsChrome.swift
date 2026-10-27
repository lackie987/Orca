import WebKit

/// The scripts that dress the window and the theme: the traffic-light preset the page can set, the
/// base colour it publishes for the startup surface, the theme mirror the shell applies to AppKit,
/// and the drag band that turns the page header into a window title bar.
extension WebPageScripts {

    /// Exposes the title-bar bridge so the `dsh-orca-titlebar` plugin can read and set the
    /// traffic-light visibility mode through `window.__ORCA_TITLEBAR__`.
    static let titleBar = #"""
    (function () {
      if (window.__ORCA_TITLEBAR__ !== undefined) { return; }
      try {
        Object.defineProperty(window, '__ORCA_TITLEBAR__', {
          configurable: true,
          value: {
            get: function () {
              return window.webkit.messageHandlers.orcaTitleBar.postMessage({ kind: 'get' });
            },
            set: function (mode) {
              return window.webkit.messageHandlers.orcaTitleBar.postMessage({ kind: 'set', mode: mode });
            }
          }
        });
      } catch (error) {}
    })();
    """#

    /// Exposes the page-side theme bridge: `window.__ORCA_PALETTE__.set('#191724')` hands the base
    /// colour of the painted plane to the native shell, which remembers it for the startup surface.
    static let palette = #"""
    (function () {
      if (window.__ORCA_PALETTE__ !== undefined) { return; }
      try {
        Object.defineProperty(window, '__ORCA_PALETTE__', {
          configurable: true,
          value: {
            get: function () {
              return window.webkit.messageHandlers.orcaPalette.postMessage({ kind: 'get' });
            },
            set: function (base) {
              return window.webkit.messageHandlers.orcaPalette.postMessage({ kind: 'set', base: base });
            }
          }
        });
      } catch (error) {}
    })();
    """#

    /// Mirrors the web UI theme source so native chrome follows the page palette.
    ///
    /// Only an explicit `data-ds-theme-source` is sent: before the host writes it, defaulting to
    /// `system` would report the Mac's scheme as if it were the saved theme and let the startup
    /// surface follow a transient plane.
    static let theme = #"""
    (function () {
      function sendTheme() {
        try {
          var source = document.documentElement.getAttribute('data-ds-theme-source');
          if (!source) { return; }
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

    /// Reports the page header height so the hidden title bar keeps a matching drag band.
    static let dragZone = #"""
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
}
