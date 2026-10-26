import AppKit

/// Applies an icon to every native surface and persists a picture the user picked.
///
/// One composed image drives the running Dock / app-switcher tile, the `.app`'s icon file and its
/// Finder metadata. The startup surface draws the transparent mark instead, so it never depends on
/// whatever this ended up writing. Keeping the system calls in one place means the bridge and the
/// launch-time apply cannot drift apart.
enum AppIconInstaller {
    /// Pushes `icon` to the running Dock tile, the `.app`'s icon file and its Finder metadata.
    ///
    /// The bundle's `AppIcon.icns` is what Finder and the next launch read, so writing it is what
    /// makes the choice survive quitting — `NSWorkspace` metadata alone is wiped whenever the bundle
    /// is replaced. Both copies are kept in step; if either write fails, the other still shows the
    /// choice.
    static func apply(_ icon: NSImage, forApp appPath: String) {
        NSApp.applicationIconImage = icon
        let bundleIcon = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("AppIcon.icns")
        _ = IcnsWriter.write(icon, to: bundleIcon)
        let workspace = NSWorkspace.shared
        // Finder caches the bundle icon; the custom-icon record is what makes it refresh after the
        // app quits. It leaves an `Icon\r` behind, so a manual re-sign of the *installed* app must
        // clear that first — `build.sh` signs the freshly assembled bundle, so the normal flow is
        // unaffected.
        workspace.setIcon(icon, forFile: appPath, options: [])
        workspace.noteFileSystemChanged(appPath)
    }

    /// Re-resolves the saved preset without writing the bundle form of it.
    ///
    /// macOS reloads the bundle icon whenever the app becomes active, which can undo an
    /// `applicationIconImage` set earlier; the launch path re-asserts the tile on every activation
    /// (and again after a theme switch) so the saved choice is what the Dock actually shows.
    static func refreshDock(_ preferences: Preferences) {
        guard let icon = AppIcon.current(preferences) else { return }
        NSApp.applicationIconImage = icon
    }

    /// Composes and saves a picked picture, applies it, and returns the composed icon.
    ///
    /// Returns `nil` when the image cannot be processed or the saved copy cannot be written; a
    /// failed `.app` write is not fatal, because the live tile still switches.
    @discardableResult
    static func installCustom(_ image: NSImage, at url: URL, forApp appPath: String) -> NSImage? {
        guard let icon = IconProcessor.icon(from: image),
              let png = IconProcessor.pngData(icon),
              (try? png.write(to: url, options: .atomic)) != nil
        else { return nil }
        apply(icon, forApp: appPath)
        return icon
    }

    /// Applies the icon the saved preset resolves to, returning it for the startup surface.
    @discardableResult
    static func applyCurrent(_ preferences: Preferences, forApp appPath: String) -> NSImage? {
        guard let icon = AppIcon.current(preferences) else { return nil }
        apply(icon, forApp: appPath)
        // The template also lands as a real `.icns`, so an SVG + colour becomes a normal icon file.
        if preferences.appIconPreset == "template" {
            _ = IcnsWriter.write(icon, to: AppPaths.templateIcon)
        }
        return icon
    }
}
