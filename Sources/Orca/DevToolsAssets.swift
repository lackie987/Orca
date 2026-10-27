import Foundation

/// The files the developer tools are made of, as shipped inside the app bundle.
///
/// The panel UI and the page-side agent are plain web assets rather than Swift string literals: both
/// are large enough to want their own file, syntax highlighting and a place to be edited without
/// touching the shell. `build.sh` copies the folder into `Contents/Resources`.
enum DevToolsAssets {
    static let directoryName = "DevTools"

    /// Folder holding `panel.html`, `panel.css`, `panel.js` and `agent.js`.
    static var directory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent(directoryName, isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    /// Entry point for the panel UI; nil when the bundle was assembled without the assets.
    static var indexFile: URL? {
        guard let directory else { return nil }
        let index = directory.appendingPathComponent("panel.html")
        return FileManager.default.fileExists(atPath: index.path) ? index : nil
    }

    /// The page-side agent, read once and injected at document start.
    ///
    /// A missing agent cannot be reconstructed in Swift, so the shell injects nothing and says so:
    /// an empty stub would look exactly like a page that never logs anything.
    static let agentSource: String = {
        guard let directory else {
            NSLog("[Orca] DevTools assets are missing from the bundle; the panel will not work")
            return ""
        }
        do {
            return try String(contentsOf: directory.appendingPathComponent("agent.js"), encoding: .utf8)
        } catch {
            NSLog("[Orca] Could not read the DevTools agent: %@", error.localizedDescription)
            return ""
        }
    }()

    /// Whether both halves of the tool are present in this bundle.
    static var isAvailable: Bool {
        indexFile != nil && !agentSource.isEmpty
    }

    /// Shown in place of the panel when the bundle carries no assets, with the reason it is empty.
    static let missingAssetsHTML = """
    <!doctype html>
    <meta charset="utf-8">
    <style>
      :root { color-scheme: dark; }
      body {
        margin: 0; display: grid; place-items: center; height: 100vh;
        background: #191724; color: #e0def4;
        font: 13px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
      }
      p { max-width: 420px; margin: 0; text-align: center; color: #908caa; }
      strong { color: #e0def4; }
    </style>
    <p><strong>Developer tools are not installed.</strong><br>
    This build of Orca carries no <code>Resources/DevTools</code> folder, so there is no panel to
    show. Rebuild with <code>./build.sh</code> from the repository.</p>
    """
}
