import WebKit

/// Every script the shell injects into the page, and the order it runs in.
///
/// The scripts are the page half of the native bridges: they define `window.__DSH_DIRECTORY_PICKER__`,
/// `window.__ORCA_TITLEBAR__` and `window.__ORCA_PALETTE__`, mirror the theme back to the shell, and
/// report the events the native side waits for (drag-band height and the first painted frame).
enum WebPageScripts {
    /// Adds every script to the page, in the order the web view should run it.
    static func install(on userContentController: WKUserContentController) {
        for script in userScripts {
            userContentController.addUserScript(script)
        }
    }

    /// Everything the shell injects, in the order the web view should run it.
    private static var userScripts: [WKUserScript] {
        [
            WKUserScript(source: console, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: directoryPicker, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: titleBar, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: palette, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: dragZone, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: theme, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
            WKUserScript(source: pagePainted, injectionTime: .atDocumentEnd, forMainFrameOnly: true),
        ]
    }

    /// Forwards console errors and uncaught exceptions to the native diagnostic log.
    private static let console = #"""
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
    private static let directoryPicker = #"""
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

    /// Exposes the title-bar bridge so the `dsh-orca-titlebar` plugin can read and set the
    /// traffic-light visibility mode through `window.__ORCA_TITLEBAR__`.
    private static let titleBar = #"""
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
    private static let palette = #"""
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

    /// Reports the page header height so the hidden title bar keeps a matching drag band.
    private static let dragZone = #"""
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
    private static let theme = #"""
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

    /// Reports the first painted frame of the document, which is the shell's cue to hand over.
    ///
    /// Two animation frames are requested after the load event because `load` fires before the
    /// compositor has a frame of the new document; the second callback lands after it does.
    private static let pagePainted = #"""
    (function () {
      if (window.__ORCA_PAGE_PAINTED__) { return; }
      window.__ORCA_PAGE_PAINTED__ = true;
      var reported = false;
      function report() {
        if (reported) { return; }
        reported = true;
        requestAnimationFrame(function () {
          requestAnimationFrame(function () {
            try {
              window.webkit.messageHandlers.orcaPagePainted.postMessage({ kind: 'painted' });
            } catch (error) {}
          });
        });
      }
      if (document.readyState === 'complete') {
        report();
      } else {
        window.addEventListener('load', report, { once: true });
      }
    })();
    """#
}
