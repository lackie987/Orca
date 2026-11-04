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
    /// through `window.__ORCA_APP_ICON__`: built-in presets, the tri-state follow mode, the current
    /// theme variant, a custom picture and a reset to the initial icon.
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
            setFollowMode: function (mode) {
              return window.webkit.messageHandlers.orcaAppIcon.postMessage({ kind: 'followMode', mode: mode });
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

    /// Publishes the native setting before `inputCompletion` runs at document end.
    static func inputCompletionDefault(_ disabled: Bool) -> String {
        let value = disabled ? "true" : "false"
        return "(function(){try{Object.defineProperty(window,'__ORCA_INPUT_COMPLETION_DEFAULT__',{configurable:true,value:\(value)});}catch(e){}})();"
    }

    /// Strips the system auto-completion / autocorrection / spell-check hints from every text input
    /// and rich-text editor in the page — including the React-mounted chat box, which arrives long
    /// after the initial DOM. The native setting can turn the whole layer on or off at runtime:
    /// `window.__ORCA_INPUT_COMPLETION__.set(false)` restores each element's previous attributes.
    static let inputCompletion = #"""
    (function () {
      var ATTRS = [
        ['autocomplete', 'off'],
        ['autocorrect', 'off'],
        ['autocapitalize', 'off'],
        ['spellcheck', 'false']
      ];
      var SELECTOR = 'input, textarea, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]';
      var NON_TEXT_INPUT_TYPES = {
        checkbox: 1, radio: 1, button: 1, submit: 1, reset: 1, image: 1, file: 1, color: 1, range: 1, hidden: 1
      };
      var previous = new WeakMap();
      var enabled = window.__ORCA_INPUT_COMPLETION_DEFAULT__ !== false;

      function eligible(element) {
        if (!element || element.nodeType !== 1) { return false; }
        if (element.tagName === 'TEXTAREA') { return true; }
        if (element.tagName === 'INPUT') {
          var type = (element.getAttribute('type') || 'text').toLowerCase();
          return NON_TEXT_INPUT_TYPES[type] !== 1;
        }
        return element.matches
          ? element.matches('[contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]')
          : false;
      }

      function disable(element) {
        if (!enabled || !eligible(element)) { return; }
        try {
          // Re-setting an attribute to the value it already holds still invalidates style on the
          // node, and the chat box is restyled on every keystroke. Once this element is recorded
          // and already carries the hints, there is nothing left to write.
          if (previous.has(element)) {
            var settled = true;
            for (var k = 0; k < ATTRS.length; k += 1) {
              if (element.getAttribute(ATTRS[k][0]) !== ATTRS[k][1]) { settled = false; break; }
            }
            if (settled) { return; }
          }
          if (!previous.has(element)) {
            var saved = {};
            for (var i = 0; i < ATTRS.length; i += 1) {
              saved[ATTRS[i][0]] = element.getAttribute(ATTRS[i][0]);
            }
            previous.set(element, saved);
          }
          for (var j = 0; j < ATTRS.length; j += 1) {
            element.setAttribute(ATTRS[j][0], ATTRS[j][1]);
          }
        } catch (error) {}
      }

      function restore(element) {
        var saved = previous.get(element);
        if (!saved) { return; }
        try {
          for (var i = 0; i < ATTRS.length; i += 1) {
            var name = ATTRS[i][0];
            if (saved[name] === null) {
              element.removeAttribute(name);
            } else {
              element.setAttribute(name, saved[name]);
            }
          }
        } catch (error) {}
        previous.delete(element);
      }

      function scan(root) {
        if (!root) { return; }
        if (root.nodeType === 1 && eligible(root)) { disable(root); }
        if (root.querySelectorAll) {
          var nodes = root.querySelectorAll(SELECTOR);
          for (var index = 0; index < nodes.length; index += 1) { disable(nodes[index]); }
        }
      }

      function set(next) {
        enabled = !!next;
        try {
          if (enabled) { scan(document); return; }
          var nodes = document.querySelectorAll(SELECTOR);
          for (var index = 0; index < nodes.length; index += 1) { restore(nodes[index]); }
        } catch (error) {}
      }

      function onMutations(records) {
        if (!enabled) { return; }
        // One record set can name the same element more than once (a move is a removal plus an
        // addition), and each name used to cost a subtree query of its own.
        var seen = null;
        for (var r = 0; r < records.length; r += 1) {
          var record = records[r];
          if (record.type === 'attributes') {
            disable(record.target);
            continue;
          }
          var added = record.addedNodes;
          for (var n = 0; n < added.length; n += 1) {
            var node = added[n];
            if (node.nodeType !== 1) { continue; }
            if (seen === null) { seen = []; }
            if (seen.indexOf(node) >= 0) { continue; }
            seen.push(node);
            scan(node);
          }
        }
      }

      if (enabled) { scan(document); }
      new MutationObserver(onMutations).observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['contenteditable']
      });
      window.__ORCA_INPUT_COMPLETION__ = {
        set: set,
        get: function () { return enabled; }
      };
    })();
    """#
}
