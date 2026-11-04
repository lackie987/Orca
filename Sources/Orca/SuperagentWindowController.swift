import AppKit
import WebKit

/// A second window showing the dsh-superagent panel.
///
/// dsh-superagent runs in its own dsh profile, booted by `scripts/dsh-superagent` rather than by
/// this shell, so Orca never sees the service's stdout. The launch token is minted per process and
/// appears only in that service's log, which leaves two options for the panel: read the token from
/// the newest log, or make the operator paste it. The window reads the log each time it is shown
/// and again after a 401, because every restart of the service mints a new token.
final class SuperagentWindowController: NSWindowController, WKNavigationDelegate {
    /// Checkout artefacts directory, overridable with
    /// `defaults write com.xu.orca superagentLogDirectory <path>` for a checkout elsewhere.
    private static let logDirectoryDefault = "~/Documents/dsh/dsh-superagent-prototype/.artifacts"
    /// The token is opaque, so the match runs to the end of the URL rather than over a character class.
    private static let accessURLPattern = try! NSRegularExpression(
        pattern: #"http://127\.0\.0\.1:\d+/\?token=[^\s"'<>]+"#
    )

    private let webView: WKWebView
    /// One retry per presentation: a token read before a restart cannot fix the next 401, but an
    /// endless reload loop would hide the real cause.
    private var tokenRetried = false

    init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Superagent"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        super.init(window: window)
        webView.navigationDelegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("Orca does not support nib loading")
    }

    /// Reads the current access URL and shows the window, reusing it when it is already open.
    func present() {
        tokenRetried = false
        if let url = accessURL() {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(Self.unavailablePage, baseURL: nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Token discovery

    /// Finds the newest log that carries an access URL, newest file first.
    ///
    /// The script keeps the twenty newest logs, and an older one still answers with a dead token, so
    /// the scan stops at the first file that has a URL rather than at the newest file.
    private func accessURL() -> URL? {
        let directory = Self.logDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let logs = names
            .filter { $0.hasPrefix("dsh-superagent-") && $0.hasSuffix(".log") }
            .map { directory + "/" + $0 }
            .sorted { modificationDate($0) > modificationDate($1) }
        for path in logs {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard
                let match = Self.accessURLPattern.matches(in: text, range: range).last,
                let found = Range(match.range, in: text),
                let url = URL(string: String(text[found]))
            else { continue }
            return url
        }
        return nil
    }

    private func modificationDate(_ path: String) -> Date {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private static var logDirectory: String {
        let configured = UserDefaults.standard.string(forKey: "superagentLogDirectory")
        let path = configured.flatMap { $0.isEmpty ? nil : $0 } ?? logDirectoryDefault
        return (path as NSString).expandingTildeInPath
    }

    // MARK: - WKNavigationDelegate

    /// A 401 means the token in the log was replaced by a restart since this window read it. Re-read
    /// once, then let the page speak for itself.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard
            !tokenRetried,
            (response.response as? HTTPURLResponse)?.statusCode == 401,
            let url = accessURL()
        else {
            decisionHandler(.allow)
            return
        }
        tokenRetried = true
        decisionHandler(.cancel)
        webView.load(URLRequest(url: url))
    }

    /// Shown when no log carries a URL yet: the fix is on the operator's side, so the page says so.
    private static let unavailablePage = """
        <!doctype html><meta charset="utf-8">
        <style>
        :root { color-scheme: light dark }
        body { font: 13px -apple-system, "Helvetica Neue", sans-serif; margin: 0; display: grid;
               place-items: center; height: 100vh; opacity: .75 }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace }
        p { margin: 6px 0 }
        </style>
        <div>
          <p>dsh-superagent is not running, or its log has no access URL yet.</p>
          <p>Start it in the checkout: <code>scripts/dsh-superagent start</code></p>
          <p>Then reopen this window.</p>
        </div>
        """
}
