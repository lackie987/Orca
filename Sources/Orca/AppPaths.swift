import Foundation

/// Filesystem locations the Orca shell owns.
enum AppPaths {
    /// `~/Library/Application Support/Orca`, created on first access.
    static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Orca", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// `~/Library/Logs/Orca`, created on first access.
    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Logs/Orca", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Captured stdout and stderr of the child `dsh web` process.
    static var serviceLog: URL {
        logs.appendingPathComponent("service.log")
    }

    /// Private record that lets a later launch reconnect to a kept-alive service.
    static var serviceSession: URL {
        applicationSupport.appendingPathComponent("session.json")
    }

    /// Keybinding overrides written by DSH's desktop shortcut editor.
    static var keybindings: URL {
        applicationSupport.appendingPathComponent("keybindings.json")
    }

    /// Processed (square, scaled) copy of the custom app icon; absent when the bundled icon is in
    /// use. Kept here rather than in the `.app` so the startup surface can reload it at launch.
    static var customAppIcon: URL {
        applicationSupport.appendingPathComponent("app-icon.png")
    }

    /// Planes of the variant the theme pack chose, written by the pack's Host while Orca was not
    /// running. Read once per launch: the page's own storage holds the variant, so this file is the
    /// only way a cold start can know the theme it is about to be handed.
    static var themePlanes: URL {
        applicationSupport.appendingPathComponent("theme.json")
    }

    /// Real `.icns` generated from the SVG template plus its background colour, so the template
    /// yields a normal macOS icon file rather than only an in-memory image.
    ///
    /// No longer written. Nothing ever read it back, and `applyCurrent` rebuilt it on every launch,
    /// activation and theme switch — a full seven-size PNG encode on the main thread each time.
    /// Kept in case a future consumer wants the file again.
    // static var templateIcon: URL {
    //     applicationSupport.appendingPathComponent("template-icon.icns")
    // }
}
