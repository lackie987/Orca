import WebKit

/// The scripts that wire the page itself: the two-way bridges it calls into the shell with (the
/// workspace directory picker, the Dock icon), the diagnostics channel that carries its console, the
/// first-painted-frame report that releases the startup surface, and the input cleanup that keeps
/// macOS auto-completion out of the chat box.
extension WebPageScripts {

    /// Forwards console errors and uncaught exceptions to the native diagnostic log.
    static let console = #"""
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
    static let directoryPicker = #"""
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

    /// Exposes the app-icon bridge so the `dsh-app-icon` plugin can read and change Orca's icon
    /// through `window.__ORCA_APP_ICON__`: built-in presets, theme-following, the current theme
    /// variant, a custom picture and a reset to the initial icon.
    static let appIcon = #"""
    (function () {
      if (window.__ORCA_APP_ICON__ !== undefined) { return; }
      try {
        Object.defineProperty(window, '__ORCA_APP_ICON__', {
          configurable: true,
          value: {
            get: function () {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'get' });
            },
            setPreset: function (preset) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'preset', preset: preset });
            },
            setFollow: function (follow) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'follow', follow: follow });
            },
            setThemeVariant: function (variant) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'variant', variant: variant });
            },
            setTemplate: function (color) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'template', color: color });
            },
            setTemplateFollow: function (follow) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'templateFollow', follow: follow });
            },
            getPreviews: function (only) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'previews', only: only });
            },
            set: function () {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'set' });
            },
            reset: function () {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'reset' });
            }
          }
        });
      } catch (error) {}
    })();
    """#

    /// Reports the first painted frame of the document, which is the shell's cue to hand over.
    ///
    /// Two animation frames are requested after the load event because `load` fires before the
    /// compositor has a frame of the new document; the second callback lands after it does.
    static let pagePainted = #"""
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

    /// Strips the system auto-completion / autocorrection / spell-check "补全提示" from every input
    /// surface inside the page — including the React-mounted chat box, which arrives long after the
    /// initial DOM. A `MutationObserver` keeps newly inserted fields in line.
    static let inputCompletion = #"""
    (function () {
      function disable(element) {
        if (!element || element.nodeType !== 1) { return; }
        try {
          element.setAttribute('autocomplete', 'off');
          element.setAttribute('autocorrect', 'off');
          element.setAttribute('autocapitalize', 'off');
          element.setAttribute('spellcheck', 'false');
        } catch (error) {}
      }
      function scan(root) {
        var nodes = (root || document).querySelectorAll('input, textarea');
        for (var index = 0; index < nodes.length; index += 1) { disable(nodes[index]); }
      }
      function onMutations(records) {
        for (var r = 0; r < records.length; r += 1) {
          var added = records[r].addedNodes;
          for (var n = 0; n < added.length; n += 1) {
            var node = added[n];
            if (node.nodeType !== 1) { continue; }
            if (node.matches && node.matches('input, textarea')) { disable(node); }
            if (node.querySelectorAll) { scan(node); }
          }
        }
      }
      scan(document);
      new MutationObserver(onMutations).observe(document.documentElement, {
        childList: true,
        subtree: true
      });
    })();
    """#
}
