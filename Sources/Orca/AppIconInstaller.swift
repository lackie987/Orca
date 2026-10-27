import AppKit

/// Applies an icon to both native surfaces and persists a picture the user picked.
///
/// One composed image drives the running Dock / app-switcher tile and the `.app`'s icon file — the
/// file Finder reads on its own, so no separate metadata record is written. The startup surface
/// draws the transparent mark instead, so it never depends on whatever this ended up writing.
/// Keeping the system calls in one place means the bridge and the launch-time apply cannot drift
/// apart.
enum AppIconInstaller {
    /// Pushes `icon` to the running Dock tile and the `.app`'s icon file.
    ///
    /// The bundle's `AppIcon.icns` is what Finder, the next launch and LaunchServices read, so
    /// writing it is what makes the choice survive quitting — `NSWorkspace` metadata alone is wiped
    /// whenever the bundle is replaced. It is also a sealed resource, so a write is followed by a
    /// fresh signature (see `AppBundleSeal`), and the bundle's timestamp is bumped so the system
    /// stops serving the icon it cached (see `markBundleChanged`).
    static func apply(_ icon: NSImage, forApp appPath: String) {
        NSApp.applicationIconImage = icon
        let bundleIcon = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("AppIcon.icns")
        // `NSWorkspace.setIcon` used to accompany the write so Finder would refresh. Its
        // custom-icon record is `com.apple.FinderInfo` on the bundle, which `codesign` refuses to
        // sign at all — every colour change then left the installed app unsealable. The bundled
        // icns is the icon Finder reads on its own, so the timestamp below is what is needed.
        if IcnsWriter.writeIfChanged(icon, to: bundleIcon) {
            AppBundleSeal.schedule(for: appPath)
        }
        markBundleChanged(appPath)
    }

    /// Marks the bundle as freshly changed, which is what makes the system re-read its icon.
    ///
    /// LaunchServices and IconServices validate the icon record they keep for a bundle against the
    /// bundle's own modification date, not against `Contents/Resources/AppIcon.icns` three levels
    /// down. Rewriting that file therefore left the record valid and Finder and the Dock kept drawing
    /// the icon they had cached, so a chosen colour looked unsaved after quitting while the file on
    /// disk already carried it. Writing the icon is only half of an update; this is the other half.
    ///
    /// The icon is newer than the bundle's mark exactly when it changed since the bundle was last
    /// marked, so steady-state launches stay silent instead of re-indexing the app every time.
    private static func markBundleChanged(_ appPath: String) {
        let manager = FileManager.default
        let bundle = URL(fileURLWithPath: appPath)
        let icon = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
        let marked = (try? manager.attributesOfItem(atPath: bundle.path))?[.modificationDate] as? Date
        let written = (try? manager.attributesOfItem(atPath: icon.path))?[.modificationDate] as? Date
        if let marked, let written, written <= marked { return }
        try? manager.setAttributes([.modificationDate: written ?? Date()], ofItemAtPath: appPath)
        NSWorkspace.shared.noteFileSystemChanged(appPath)
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
