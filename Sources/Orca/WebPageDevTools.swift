import WebKit

extension WebPageController: DevToolsPageBridge {
    /// Runs `__ORCA_DEVTOOLS__.handle(command)` in the page and hands the result back.
    ///
    /// `callAsyncJavaScript` is what lets `console.eval` resolve promises the way a console does; it
    /// also keeps the call inside the page's own content world, so the app's scripts cannot observe
    /// or intercept it.
    func devToolsCall(_ command: [String: Any], completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(
            "return await window.__ORCA_DEVTOOLS__.handle(command)",
            arguments: ["command": command],
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success(let value):
                completion(value)
            case .failure(let error):
                // Reported as the command's failure; the panel shows it rather than inventing an answer.
                completion(["error": error.localizedDescription])
            }
        }
    }
}
