import WebKit

/// The script that makes the page boot as a desktop application.
///
/// It is the largest injected script by far because it is an impersonation: `data-platform="darwin"`
/// switches the page to its macOS layout, and `window.dshDesktop` has to answer the shortcut service
/// while that service constructs itself — then disappear, so the account, onboarding and chat
/// plugins stay on their web paths. The storage adapter persists the same revisioned document the
/// desktop editor writes, and the keyboard bridge forwards physical keys with that revision.
extension WebPageScripts {

    /// Boots the page as a desktop shell and exposes the bridges DSH's desktop runtime expects.
    ///
    /// `data-platform` switches the page to its macOS desktop layout. The `dshDesktop` bridge is
    /// attached only while DSH's shortcut service is constructed: that service captures the
    /// keyboard and storage adapters and keeps working after the global is removed, while the
    /// account, onboarding, and chat plugins stay on their web paths. The storage adapter persists
    /// the same revisioned document the desktop editor writes, and the keyboard bridge forwards
    /// physical keys with the current revision.
    static let desktop = #"""
    (function () {
      if (window.__ORCA_DESKTOP__) { return; }
      var root = document.documentElement;
      if (!root) { return; }
      root.setAttribute('data-platform', 'darwin');

      var bridge = window.webkit && window.webkit.messageHandlers
        ? window.webkit.messageHandlers.orcaDesktop
        : undefined;

      function request(kind, payload) {
        if (!bridge) { return Promise.reject(new Error('Orca desktop bridge unavailable')); }
        var message = { kind: kind };
        if (payload) {
          for (var key in payload) {
            if (Object.prototype.hasOwnProperty.call(payload, key)) { message[key] = payload[key]; }
          }
        }
        return bridge.postMessage(message);
      }

      var profile = 'desktop:macos';
      var sequence = 0;
      var current = null;
      var loading = null;
      var definitions = [];
      var preferenceListeners = new Set();
      var keyboardListeners = new Set();
      var held = new Set();
      var recording = false;
      var moduleLoader;

      function newRevision() {
        if (window.crypto && typeof window.crypto.randomUUID === 'function') {
          return window.crypto.randomUUID();
        }
        return 'orca-' + Date.now().toString(16) + '-' + Math.random().toString(16).slice(2);
      }

      function emptyDocument() {
        return { schemaVersion: 2, profiles: {} };
      }

      function validBinding(binding) {
        if (binding === null) { return true; }
        if (binding === undefined || typeof binding !== 'object' || Array.isArray(binding)) { return false; }
        if (typeof binding.code !== 'string' || binding.code.length === 0) { return false; }
        if (!Array.isArray(binding.modifiers)) { return false; }
        for (var index = 0; index < binding.modifiers.length; index += 1) {
          var modifier = binding.modifiers[index];
          if (modifier !== 'primary' && modifier !== 'control' && modifier !== 'alt'
              && modifier !== 'shift' && modifier !== 'meta') { return false; }
        }
        if (binding.secondCode !== undefined && typeof binding.secondCode !== 'string') { return false; }
        return true;
      }

      function parse(raw) {
        if (raw === null || raw === undefined || raw === '') {
          return { document: emptyDocument(), status: 'ready', error: null, usingDefaults: true };
        }
        try {
          var value = JSON.parse(raw);
          if (value === null || typeof value !== 'object' || Array.isArray(value)) { throw new Error('shape'); }
          var version = value.schemaVersion;
          if (version !== 1 && version !== 2) {
            if (typeof version === 'number' && version > 2) {
              return { document: emptyDocument(), status: 'unreadable', error: 'future', usingDefaults: true };
            }
            throw new Error('version');
          }
          var profiles = value.profiles;
          if (profiles === null || typeof profiles !== 'object' || Array.isArray(profiles)) {
            throw new Error('profiles');
          }
          var document = { schemaVersion: version, profiles: {} };
          Object.keys(profiles).forEach(function (name) {
            if (!/^(desktop|web):(macos|windows|linux)$/.test(name)) { throw new Error('profile'); }
            var overrides = profiles[name];
            if (overrides === null || typeof overrides !== 'object' || Array.isArray(overrides)) {
              throw new Error('overrides');
            }
            var clean = {};
            Object.keys(overrides).forEach(function (id) {
              var binding = overrides[id];
              if (!validBinding(binding)) { throw new Error('binding'); }
              clean[id] = binding;
            });
            document.profiles[name] = clean;
          });
          return { document: document, status: 'ready', error: null, usingDefaults: false };
        } catch (error) {
          return { document: emptyDocument(), status: 'unreadable', error: 'invalid', usingDefaults: true };
        }
      }

      function snapshot(parsed) {
        sequence += 1;
        return {
          revision: newRevision(),
          sequence: sequence,
          document: parsed.document,
          status: parsed.status,
          error: parsed.error,
          usingDefaults: parsed.usingDefaults
        };
      }

      function publish() {
        if (current === null) { return; }
        preferenceListeners.forEach(function (listener) {
          try { listener(current); } catch (error) { console.error(error); }
        });
      }

      function read() {
        if (current !== null) { return Promise.resolve(current); }
        if (loading === null) {
          loading = request('shortcuts.read').then(function (raw) {
            current = snapshot(parse(raw));
            return current;
          }, function () {
            current = snapshot({ document: emptyDocument(), status: 'unreadable', error: 'read', usingDefaults: true });
            return current;
          });
        }
        return loading;
      }

      function editDocument(document, edit) {
        var next = JSON.parse(JSON.stringify(document));
        var profiles = next.profiles;
        var overrides = profiles[profile];
        if (edit.type === 'reset-all') {
          delete profiles[profile];
          return next;
        }
        if (overrides === undefined) {
          overrides = {};
          profiles[profile] = overrides;
        }
        if (edit.type === 'set') {
          if (typeof edit.id !== 'string' || edit.id.length === 0 || !validBinding(edit.binding)) {
            throw new Error('edit');
          }
          overrides[edit.id] = edit.binding;
          if (edit.binding !== null && edit.binding.secondCode !== undefined) { next.schemaVersion = 2; }
          return next;
        }
        if (edit.type === 'reset') {
          if (typeof edit.id !== 'string' || edit.id.length === 0) { throw new Error('edit'); }
          delete overrides[edit.id];
          return next;
        }
        throw new Error('edit');
      }

      function applyEdit(edit, expectedRevision) {
        if (current === null || current.status !== 'ready') {
          return { status: 'not-ready', snapshot: current || snapshot(parse(null)) };
        }
        if (expectedRevision !== current.revision) {
          return { status: 'stale', snapshot: current };
        }
        var document;
        try {
          document = editDocument(current.document, edit);
        } catch (error) {
          return { status: 'conflict', snapshot: current };
        }
        return request('shortcuts.write', { raw: JSON.stringify(document) }).then(function () {
          current = snapshot({ document: document, status: 'ready', error: null, usingDefaults: false });
          publish();
          return { status: 'saved', snapshot: current };
        }, function () {
          return { status: 'write-failed', snapshot: current };
        });
      }

      var shortcuts = {
        get: function (incoming) {
          if (Array.isArray(incoming)) { definitions = incoming; }
          return read();
        },
        edit: function (edit, expectedRevision) {
          return read().then(function () { return applyEdit(edit, expectedRevision); });
        },
        subscribe: function (listener) {
          preferenceListeners.add(listener);
          return function () { preferenceListeners.delete(listener); };
        },
        recording: function (active) {
          recording = active === true;
          if (recording) { held.clear(); }
          return Promise.resolve();
        }
      };

      var modifierCodes = {
        ShiftLeft: true, ShiftRight: true,
        ControlLeft: true, ControlRight: true,
        AltLeft: true, AltRight: true,
        MetaLeft: true, MetaRight: true,
        CapsLock: true, Function: true, Fn: true
      };

      function emit(input) {
        if (current === null || current.status !== 'ready') { return; }
        keyboardListeners.forEach(function (listener) {
          try { listener(input); } catch (error) { console.error(error); }
        });
      }

      window.addEventListener('keydown', function (event) {
        if (recording || event.defaultPrevented || event.isComposing || event.keyCode === 229) { return; }
        if (!event.code || modifierCodes[event.code] || event.key === 'Dead' || event.code === 'Unidentified') {
          return;
        }
        var secondCode;
        if (held.size > 0) {
          held.forEach(function (code) {
            if (secondCode === undefined && code !== event.code) { secondCode = code; }
          });
        }
        held.add(event.code);
        if (current === null || current.status !== 'ready') { return; }
        var input = {
          revision: current.revision,
          kind: 'keyboard',
          frameName: '',
          code: event.code,
          control: event.ctrlKey,
          alt: event.altKey,
          shift: event.shiftKey,
          meta: event.metaKey,
          repeat: event.repeat
        };
        if (secondCode !== undefined) { input.secondCode = secondCode; }
        emit(input);
      }, true);

      window.addEventListener('keyup', function (event) {
        held.delete(event.code);
      }, true);

      window.addEventListener('blur', function () {
        held.clear();
      }, true);

      document.addEventListener('visibilitychange', function () {
        if (document.hidden) { held.clear(); }
      }, true);

      var keyboard = {
        subscribe: function (listener) {
          keyboardListeners.add(listener);
          return function () { keyboardListeners.delete(listener); };
        },
        closeWindow: function (expectedRevision) {
          if (current === null || expectedRevision !== current.revision) { return Promise.resolve(); }
          return request('closeWindow').then(function () {}, function () {});
        }
      };

      var desktopApi = {
        shortcuts: shortcuts,
        keyboard: keyboard,
        deviceInfo: function () { return request('deviceInfo'); }
      };

      function attachDesktopBridge() {
        window.__ORCA_SHORTCUTS_ATTACHED__ = true;
        try {
          Object.defineProperty(window, 'dshDesktop', {
            configurable: true,
            value: desktopApi
          });
        } catch (error) {}
      }

      function detachDesktopBridge() {
        try { delete window.dshDesktop; } catch (error) {}
      }

      function wrapShortcuts(factory) {
        return function (require) {
          var exported = factory(require);
          if (typeof exported !== 'function') { return exported; }
          var proxy = new Proxy(exported, {
            construct: function (target, args, newTarget) {
              attachDesktopBridge();
              try {
                return Reflect.construct(target, args, newTarget === proxy ? target : newTarget);
              } finally {
                detachDesktopBridge();
              }
            },
            apply: function (target, thisArg, args) {
              attachDesktopBridge();
              try {
                return Reflect.apply(target, thisArg, args);
              } finally {
                detachDesktopBridge();
              }
            }
          });
          return proxy;
        };
      }

      function wrapRegistration(registration) {
        if (registration && typeof registration.factory === 'function'
            && String(registration.id).indexOf('dsh-client-shortcuts') >= 0) {
          return Object.assign({}, registration, {
            factory: wrapShortcuts(registration.factory)
          });
        }
        return registration;
      }

      function wrapLoader(loader) {
        if (!loader || typeof loader.load !== 'function' || loader.__orcaShortcutHook) { return loader; }
        var load = loader.load;
        loader.load = function (registration) {
          return load.call(this, wrapRegistration(registration));
        };
        loader.__orcaShortcutHook = true;

        var create = loader.create;
        if (typeof create === 'function') {
          loader.create = function (options) {
            var modules = create.call(this, options);
            if (modules && typeof modules.register === 'function' && !modules.__orcaShortcutHook) {
              var register = modules.register;
              modules.register = function (registration) {
                return register.call(this, wrapRegistration(registration));
              };
              modules.__orcaShortcutHook = true;
            }
            return modules;
          };
        }
        return loader;
      }

      try {
        Object.defineProperty(window, '__ModuleLoader__', {
          configurable: true,
          get: function () { return moduleLoader; },
          set: function (value) { moduleLoader = wrapLoader(value); }
        });
      } catch (error) {
        // The inline head script could not be intercepted; keep the bridge visible so the
        // shortcut service still starts, at the cost of exposing it to later plugins.
        attachDesktopBridge();
      }

      window.__ORCA_DESKTOP__ = true;

      window.setTimeout(function () {
        if (!window.__ORCA_SHORTCUTS_ATTACHED__) {
          console.error('[Orca] desktop shortcut bridge was not installed');
        }
      }, 3000);
    })();
    """#
}
