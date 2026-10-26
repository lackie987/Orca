import WebKit

/// Carries the page's `localStorage` across a change of origin.
///
/// WebKit keys `localStorage` by origin, and the origin here is `http://127.0.0.1:<port>` — so every
/// launch that lands on a different port hands the page a brand-new, empty store and every plugin
/// falls back to its initial state. JavaScript cannot read another origin's store, so the entries
/// are snapshotted from the page still showing the old origin and replayed into the new one at
/// `documentStart`, before any plugin script has run.
///
/// A replay is built for one specific port and marks the load in `sessionStorage`, so it fires
/// exactly once per page load: a later reload keeps whatever the plugins wrote in the meantime, and
/// a migration back to a previous port replays the data that is current at that moment rather than
/// a stale copy.
enum WebPageStorage {
    /// The entries of one origin, remembered until the next origin is served.
    struct Snapshot {
        /// Port of the origin the entries were read from.
        let port: Int
        /// Entries to carry over; `localStorage` itself is unordered.
        let data: [String: String]
    }

    /// Reads every entry of the document the web view currently shows.
    /// - Parameters:
    ///   - webView: view holding the page to read.
    ///   - completion: called on the main queue with the snapshot, or `nil` when there is nothing
    ///     to carry (no document, a foreign origin, or an empty store).
    static func capture(from webView: WKWebView, completion: @escaping (Snapshot?) -> Void) {
        let script = """
        (function(){try{
          var keys = Object.keys(localStorage)
          var pairs = []
          for (var i = 0; i < keys.length; i++) { pairs.push([keys[i], localStorage.getItem(keys[i]) || '']) }
          return JSON.stringify(pairs)
        }catch(e){return ''}})()
        """
        webView.evaluateJavaScript(script) { result, error in
            guard error == nil,
                  let text = result as? String, !text.isEmpty,
                  let raw = text.data(using: .utf8),
                  let pairs = try? JSONSerialization.jsonObject(with: raw) as? [[String]],
                  let port = webView.url?.port
            else {
                completion(nil)
                return
            }
            var data: [String: String] = [:]
            for pair in pairs where pair.count == 2 { data[pair[0]] = pair[1] }
            completion(data.isEmpty ? nil : Snapshot(port: port, data: data))
        }
    }

    /// Builds the `documentStart` script that replays `snapshot` into the origin served on `port`.
    /// - Parameters:
    ///   - port: port of the origin that is about to be loaded.
    ///   - snapshot: entries to write before any plugin script runs.
    /// - Returns: a user script that applies itself once and then marks the load as migrated.
    static func restoreScript(port: Int, snapshot: Snapshot) -> WKUserScript {
        let source = """
        (function(){try{
          if (location.port !== '\(port)') return
          if (sessionStorage.getItem('\(markerKey)') === '1') return
          var pairs = JSON.parse('\(literal(snapshot.data.map { [$0.key, $0.value] }))')
          for (var i = 0; i < pairs.length; i++) { localStorage.setItem(pairs[i][0], pairs[i][1]) }
          sessionStorage.setItem('\(markerKey)', '1')
        }catch(e){}})()
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Serialises key/value rows as JSON text that survives being embedded in a script.
    ///
    /// The JSON is carried inside a single-quoted JavaScript literal, so it has to be escaped for
    /// *that* layer as well: a raw `\"` from the JSON would be decoded by JavaScript into a bare
    /// quote and break `JSON.parse`. Backslashes are therefore escaped first, then the JSON's own
    /// escapes reach `JSON.parse` intact. `<` is written as `\u003c` so no value can close the
    /// script element early.
    /// - Parameter pairs: rows to serialise.
    /// - Returns: JSON text escaped for a single-quoted JavaScript literal; `[]` when the rows
    ///   cannot be serialised.
    private static func literal(_ pairs: [[String]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: pairs),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        var text = json
        text = text.replacingOccurrences(of: "\\", with: "\\\\")
        text = text.replacingOccurrences(of: "'", with: "\\'")
        text = text.replacingOccurrences(of: "\n", with: "\\n")
        text = text.replacingOccurrences(of: "\r", with: "\\r")
        text = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        text = text.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        text = text.replacingOccurrences(of: "<", with: "\\u003c")
        return text
    }

    /// `sessionStorage` key marking a page load as already migrated.
    private static let markerKey = "__orca_storage_migrated__"
}
