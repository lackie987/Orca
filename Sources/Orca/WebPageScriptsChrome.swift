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

    /// Exposes the native-glass bridge so the `dsh-patch` background tab can read and set whether the
    /// window keeps its system material behind the page through `window.__ORCA_GLASS__`.
    ///
    /// The native side speaks `"on"` / `"off"`; the shim takes and answers booleans so the page never
    /// has to know the wire format.
    static let glass = #"""
    (function () {
      if (window.__ORCA_GLASS__ !== undefined) { return; }
      try {
        Object.defineProperty(window, '__ORCA_GLASS__', {
          configurable: true,
          value: {
            get: function () {
              return window.webkit.messageHandlers.orcaGlass
                .postMessage({ kind: 'get' })
                .then(function (state) { return state === 'on'; });
            },
            set: function (on) {
              return window.webkit.messageHandlers.orcaGlass
                .postMessage({ kind: 'set', state: on ? 'on' : 'off' })
                .then(function (state) { return state === 'on'; });
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

    /// Exposes the page-backdrop bridge so `dsh-patch` can report that the page paints a backdrop
    /// which already covers the window.
    ///
    /// One-way on purpose: the shell stores nothing here, so there is no state for the page to read
    /// back. The report exists because the window's material samples the desktop for every frame
    /// the content changes, and an opaque wallpaper makes that sample invisible — the page can
    /// frost its own backdrop on the GPU instead, which is what this asks the shell to allow.
    static let backdrop = #"""
    (function () {
      if (window.__ORCA_BACKDROP__ !== undefined) { return; }
      try {
        Object.defineProperty(window, '__ORCA_BACKDROP__', {
          configurable: true,
          value: {
            set: function (covers) {
              try {
                window.webkit.messageHandlers.orcaBackdrop.postMessage({ covers: covers === true });
              } catch (error) {}
            }
          }
        });
      } catch (error) {}
    })();
    """#

    /// Reports the page header height so the hidden title bar keeps a matching drag band.
    ///
    /// The band follows the header's own geometry, so that is what this watches: a
    /// `ResizeObserver` on the headers costs nothing while nothing resizes, and a slow mutation
    /// tick only re-collects the header set (a header can mount late, and the hero becomes a
    /// conversation header). The earlier shape re-measured every 150 ms on any mutation, i.e. a
    /// `getBoundingClientRect()` on a dirty tree during the whole of a streaming reply, and then
    /// posted the same unchanged height to the shell.
    ///
    /// The header set is held, not re-queried: `querySelectorAll` walks the whole document, and
    /// doing that per frame made scrolling — the one interaction this has to follow — the most
    /// expensive thing the shell did. A changed height is also the only thing that crosses the
    /// bridge; a repeat carried no information and still woke the shell.
    static let dragZone = #"""
    (function () {
      let reported = -1;
      let frame = 0;
      let resizes = null;
      let collectTimer = 0;
      let scrollTimer = 0;
      /** The headers found by the last collect; emptied and refilled in place. */
      const headers = [];

      function measure() {
        let height = 0;
        for (const header of headers) {
          if (!header.isConnected) { continue; }
          const rect = header.getBoundingClientRect();
          if (rect.top <= 2 && rect.height >= 24 && rect.height <= 160 && rect.width >= 400) {
            height = Math.round(rect.height);
            break;
          }
        }
        return height;
      }

      function report() {
        const height = measure();
        if (height === reported) { return; }
        reported = height;
        try {
          window.webkit.messageHandlers.titleBar.postMessage({ height: height });
        } catch (error) {}
      }

      /** One measurement per frame, however many triggers arrive. */
      function schedule() {
        if (frame !== 0) { return; }
        frame = window.requestAnimationFrame(function () {
          frame = 0;
          report();
        });
      }

      /**
       * Scroll is followed on a slow tick, not on a frame.
       *
       * The band only flips when the header leaves the top of the window, which a scroll can
       * cause and a resize cannot report. Measuring costs a layout read per header, and a scroll
       * lasts as long as the user keeps the wheel moving, so one measurement per 150 ms answers
       * the same question without making the scroll the busiest path on the page.
       */
      function scheduleFromScroll() {
        if (scrollTimer !== 0) { return; }
        scrollTimer = window.setTimeout(function () {
          scrollTimer = 0;
          report();
        }, 150);
      }

      /** Re-collects the header set; a fresh observer drops headers that unmounted. */
      function collect() {
        collectTimer = 0;
        if (!document.body) { return; }
        headers.length = 0;
        const next = new ResizeObserver(schedule);
        for (const header of document.querySelectorAll('header')) {
          headers.push(header);
          next.observe(header);
        }
        if (resizes !== null) { resizes.disconnect(); }
        resizes = next;
        schedule();
      }

      function start() {
        report();
        window.setTimeout(schedule, 500);
        window.setTimeout(schedule, 1500);
        // 400 ms is deliberate: this only has to notice the header set changing, and a chat that
        // is streaming mutations must not turn it into a per-frame query.
        new MutationObserver(function () {
          if (collectTimer !== 0) { return; }
          collectTimer = window.setTimeout(collect, 400);
        }).observe(document.documentElement, { childList: true, subtree: true });
        window.addEventListener('resize', schedule);
        // Scroll does not bubble, so the capture phase is what sees every scrollport on the page.
        document.addEventListener('scroll', scheduleFromScroll, { capture: true, passive: true });
        collect();
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#
}
