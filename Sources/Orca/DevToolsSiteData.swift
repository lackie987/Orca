import Foundation
import WebKit

/// Cookies and whole-site data: the half of "Application" that the page cannot see for itself.
///
/// Everything here is answered from `WKWebsiteDataStore`, so the panel shows what the browser would
/// send — including `HttpOnly` cookies the document's `document.cookie` deliberately hides.
enum DevToolsSiteData {
    private static let time = ISO8601DateFormatter()

    /// Every cookie the store holds, in the shape the panel's Storage tab renders.
    static func listCookies(in store: WKWebsiteDataStore, completion: @escaping (Any?) -> Void) {
        store.httpCookieStore.getAllCookies { cookies in
            var rows: [[String: Any]] = []
            rows.reserveCapacity(cookies.count)
            for cookie in cookies {
                var row: [String: Any] = [:]
                row["name"] = cookie.name
                row["value"] = cookie.value
                row["domain"] = cookie.domain
                row["path"] = cookie.path
                row["expires"] = cookie.expiresDate.map { time.string(from: $0) } ?? "session"
                row["secure"] = cookie.isSecure
                row["httpOnly"] = cookie.isHTTPOnly
                rows.append(row)
            }
            rows.sort { left, right in
                let leftKey = "\(left["domain"] ?? "")/\(left["name"] ?? "")"
                let rightKey = "\(right["domain"] ?? "")/\(right["name"] ?? "")"
                return leftKey < rightKey
            }
            completion(["rows": rows])
        }
    }

    /// Deletes the cookie matching the name, and the domain/path when the panel supplies them.
    static func deleteCookie(_ request: [String: Any], in store: WKWebsiteDataStore, completion: @escaping (Any?) -> Void) {
        guard let name = request["name"] as? String else {
            completion(["error": "Cookie name is missing"])
            return
        }
        let domain = request["domain"] as? String
        let path = request["path"] as? String
        store.httpCookieStore.getAllCookies { cookies in
            let matches = cookies.filter { cookie in
                cookie.name == name
                    && (domain == nil || cookie.domain == domain)
                    && (path == nil || cookie.path == path)
            }
            guard !matches.isEmpty else {
                completion(["error": "That cookie is no longer in the store"])
                return
            }
            delete(matches, in: store, completion: completion)
        }
    }

    /// Deletes every cookie that belongs to the page's host.
    static func clearCookies(for origin: URL?, in store: WKWebsiteDataStore, completion: @escaping (Any?) -> Void) {
        guard let host = origin?.host else {
            completion(["error": "The page has no host yet"])
            return
        }
        store.httpCookieStore.getAllCookies { cookies in
            delete(cookies.filter { matches(cookie: $0, host: host) }, in: store, completion: completion)
        }
    }

    /// Drops every kind of storage for one origin — the "Clear site data" button.
    static func clearSiteData(for origin: URL, in store: WKWebsiteDataStore, completion: @escaping (Any?) -> Void) {
        guard let host = origin.host else {
            completion(["error": "The page has no origin yet"])
            return
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        // Site data is addressed by record, and a record is identified by its display name — the
        // origin's host. Asking the store what it holds keeps this honest: an origin with no record
        // reports nothing removed instead of pretending it cleared something.
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in
                record.displayName == host || record.displayName.hasSuffix("." + host)
            }
            guard !matching.isEmpty else {
                completion(["ok": true, "records": 0])
                return
            }
            store.removeData(ofTypes: types, for: matching) {
                completion(["ok": true, "records": matching.count])
            }
        }
    }

    // MARK: - Private

    private static func delete(_ cookies: [HTTPCookie], in store: WKWebsiteDataStore, completion: @escaping (Any?) -> Void) {
        guard !cookies.isEmpty else {
            completion(["ok": true, "removed": 0])
            return
        }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.httpCookieStore.delete(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(["ok": true, "removed": cookies.count])
        }
    }

    /// A host matches when the cookie's domain is it or a parent domain of it.
    private static func matches(cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }
}
