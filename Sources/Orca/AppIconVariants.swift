import AppKit

/// Both appearances of the saved icon, pre-rendered for the background agent.
///
/// `orca-icon-sync` runs while Orca is quit: it has no page to ask for a base colour and no renderer
/// of its own. Teaching it to compose is what went wrong before — it only knew the three
/// pre-rendered themed files, so a `template` or `custom` icon was silently replaced by a different
/// artwork. Orca therefore writes what the icon looks like in each appearance here, and the agent
/// only ever copies one of those files back into the bundle.
///
/// The manifest pins the settings the files were produced from. An agent that finds a different
/// preset, mode or theme source knows the files are stale and leaves the bundle alone, so a settings
/// change made just before quitting can never install the previous choice.
enum AppIconVariants {
    /// One appearance's artifact and the signature it was composed from.
    struct Entry: Codable {
        let signature: String
        let file: String
    }

    /// The settings the artifacts belong to, plus where to find them.
    struct Manifest: Codable {
        /// Saved preset (`template`, `custom`, a themed name, …).
        let preset: String
        /// Follow mode (`none`, `theme`, `system`).
        let mode: String
        /// Page theme source (`light`, `dark`, `system` or empty), which decides whether the page
        /// side of a `theme` icon flips with the Mac.
        let themeSource: String
        /// Keyed by `light` / `dark`. A preset that follows nothing points both at one file.
        let appearances: [String: Entry]
    }

    /// `<Application Support>/Orca/AppIconVariants`.
    static var directory: URL {
        AppPaths.applicationSupport.appendingPathComponent("AppIconVariants", isDirectory: true)
    }

    /// What the agent reads instead of guessing.
    static var manifestFile: URL {
        directory.appendingPathComponent("manifest.json")
    }

    /// The manifest key for the Mac's current scheme.
    static func appearanceKey(isDark: Bool) -> String {
        isDark ? "dark" : "light"
    }

    /// Writes both artifacts and the manifest for the saved preset.
    ///
    /// Cheap in steady state: `writeIfChanged` compares bytes, so a launch that changes nothing
    /// writes nothing. A preset that cannot differ between appearances produces one file that both
    /// manifest keys point at, halving the work for the common fixed-icon case.
    static func write(_ preferences: Preferences) {
        guard needsWrite(preferences) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearances = followsAppearance(preferences) ? renderBoth(preferences) : renderSteady(preferences)
        guard !appearances.isEmpty else { return }
        let manifest = Manifest(
            preset: preferences.appIconPreset,
            mode: AppIcon.followMode(preferences).rawValue,
            themeSource: preferences.themeSource,
            appearances: appearances
        )
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestFile, options: .atomic)
        lastKey = key(for: preferences)
        prune(keeping: Set(appearances.values.map(\.file)))
    }

    /// Whether the artifacts still describe the saved settings.
    ///
    /// Composing both appearances costs two 1024px rasterisations, so a re-assert that changes
    /// nothing — the launch, activation and theme-switch path calls this every time — has to answer
    /// without rendering. The signatures are cheap: preset names, stored colours, one file date.
    private static func needsWrite(_ preferences: Preferences) -> Bool {
        guard FileManager.default.fileExists(atPath: manifestFile.path) else { return true }
        return key(for: preferences) != lastKey
    }

    /// Everything the artifacts depend on, as one comparable string.
    private static func key(for preferences: Preferences) -> String {
        [
            preferences.appIconPreset,
            AppIcon.followMode(preferences).rawValue,
            preferences.themeSource,
            AppIcon.signature(for: preferences, isDark: false),
            AppIcon.signature(for: preferences, isDark: true)
        ].joined(separator: "|")
    }

    /// Writes both appearances after a quiet period, off the main thread.
    ///
    /// The colour well posts a new template colour on nearly every frame, and each write composes
    /// two 1024px icons and encodes fourteen PNGs; coalescing keeps a drag smooth while still leaving
    /// the artifacts ready before the window can be closed.
    static func schedule(_ preferences: Preferences, after delay: TimeInterval = 0.3) {
        pending?.cancel()
        let work = DispatchWorkItem { write(preferences) }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether the icon can differ between light and dark at all.
    ///
    /// A page pinned to one plane answers both appearances with that plane, so rendering two
    /// artifacts would only produce two copies of one icon.
    private static func followsAppearance(_ preferences: Preferences) -> Bool {
        guard AppIcon.canFollow(preferences) else { return false }
        switch AppIcon.followMode(preferences) {
        case .none: return false
        case .system: return true
        case .theme:
            return AppIcon.pageFollowsSystem(preferences) && !AppIcon.pagePinsItsPlane(preferences)
        }
    }

    /// One artifact per appearance.
    private static func renderBoth(_ preferences: Preferences) -> [String: Entry] {
        var result: [String: Entry] = [:]
        for key in ["light", "dark"] {
            let isDark = key == "dark"
            guard let icon = AppIcon.icon(preferences, isDark: isDark) else { continue }
            let file = "\(key).icns"
            _ = IcnsWriter.writeIfChanged(icon, to: directory.appendingPathComponent(file))
            result[key] = Entry(
                signature: AppIcon.signature(for: preferences, isDark: isDark),
                file: file
            )
        }
        return result
    }

    /// One artifact standing in for both appearances.
    private static func renderSteady(_ preferences: Preferences) -> [String: Entry] {
        guard let icon = AppIcon.current(preferences) else { return [:] }
        let file = "steady.icns"
        _ = IcnsWriter.writeIfChanged(icon, to: directory.appendingPathComponent(file))
        let entry = Entry(signature: AppIcon.signature(for: preferences), file: file)
        return ["light": entry, "dark": entry]
    }

    /// Deletes artifacts from a previous preset, so the directory cannot accumulate dead icons.
    private static func prune(keeping files: Set<String>) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where name.hasSuffix(".icns") && !files.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Pending debounced write; cancelled and replaced by the next call.
    private static var pending: DispatchWorkItem?

    /// Settings key of the last manifest this process wrote, so repeats answer without rendering.
    private static var lastKey: String?

    /// Serial queue for the artifact renders. `NSImage` drawing is safe off the main thread; only
    /// `NSApplication` is not, and nothing here touches it.
    private static let queue = DispatchQueue(label: "orca.appicon.variants", qos: .utility)
}
