// orca-icon-sync
// Installs the icon Orca already rendered for the Mac's current appearance, while Orca is quit.
//
// Orca only rewrites its icon from a live process: it composes the saved preset — a template
// colour, a custom picture, a themed variant — and writes the bundle's AppIcon.icns. Once quit,
// nothing updates that file, so a light/dark switch leaves the Finder icon on the appearance the
// app was quit in. This tool runs as a per-user LaunchAgent, picks the artifact Orca left in
// `~/Library/Application Support/Orca/AppIconVariants` for the current appearance, writes it into
// the bundle and re-seals it.
//
// It deliberately composes nothing. It used to copy the bundled pre-rendered themed `.icns` files,
// which cannot express a template colour or a custom picture, so any icon other than the three
// stock ones was replaced by a different artwork. Copying bytes Orca produced keeps the two exactly
// in step, and a manifest whose settings no longer match the saved ones is treated as stale — the
// bundle is then left alone rather than filled with the previous choice.

import AppKit

let appBundleID = "com.xu.orca"
let defaultInstallDir = "/Applications"
let defaultProfile = "web"

/// Run a command, returning its stdout (stderr swallowed). A missing binary or a non-zero exit
/// yields an empty string — callers treat that as "no answer".
@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let pipe = process.standardOutput as? Pipe
    process.waitUntilExit()
    return String(data: pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data(), encoding: .utf8) ?? ""
}

/// Append-only progress line for the LaunchAgent's log.
///
/// Written to stderr, not stdout: a resident process's stdout is block-buffered when it is a file,
/// so `print` would sit in the buffer and the log would look like nothing ever ran.
func note(_ message: String) {
    FileHandle.standardError.write(Data("orca-icon-sync: \(message)\n".utf8))
}

// MARK: - Where things live

/// `<Application Support>/Orca`, the same directory Orca writes its artifacts into.
var supportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Orca", isDirectory: true)
}

/// The pre-rendered appearances Orca leaves behind.
var variantsDirectory: URL {
    supportDirectory.appendingPathComponent("AppIconVariants", isDirectory: true)
}

var manifestURL: URL {
    variantsDirectory.appendingPathComponent("manifest.json")
}

/// The Orca.app this tool belongs to: prefer its own containing bundle, fall back to the default
/// install path (used when run standalone during testing).
func locateOrcaApp() -> URL {
    let url = Bundle.main.bundleURL
    if url.lastPathComponent == "Orca.app",
       FileManager.default.fileExists(
         atPath: url.appendingPathComponent("Contents/Resources/AppIcon.icns").path) {
        return url
    }
    return URL(fileURLWithPath: defaultInstallDir).appendingPathComponent("Orca.app")
}

// MARK: - Saved settings

/// Read one of Orca's preferences without opening a `UserDefaults` suite.
///
/// `UserDefaults(suiteName:)` with the app's own identifier is refused by Foundation (and logged as
/// a nonsensical suite), which is what made this tool look like it had run and done nothing.
func savedValue(_ key: String) -> String? {
    CFPreferencesCopyAppValue(key as CFString, appBundleID as CFString) as? String
}

func savedBool(_ key: String) -> Bool {
    var missing = DarwinBoolean(false)
    let value = CFPreferencesGetAppBooleanValue(key as CFString, appBundleID as CFString, &missing)
    return value
}

/// Orca's icon follow mode, migrating the legacy boolean switches the same way `AppIcon` does.
func followMode() -> String {
    let preset = (savedValue("appIconPreset") ?? "orca").lowercased()
    if let mode = savedValue("appIconFollowMode"), !mode.isEmpty { return mode.lowercased() }
    let followed = preset == "template"
        ? savedBool("appIconTemplateFollowsTheme")
        : (["dawn", "main", "moon"].contains(preset) && savedBool("appIconFollowsTheme"))
    return followed ? "system" : "none"
}

/// Page theme source: `light`, `dark`, `system`, or empty before the page has reported one.
func themeSource() -> String {
    savedValue("themeSource") ?? ""
}

/// Whether the page theme itself follows the Mac, which is when its base flips with the system.
func pageFollowsSystem() -> Bool {
    switch themeSource() {
    case "light", "dark": return false
    default: return true
    }
}

/// The DSH profile whose theme preference the page reads.
func profileName() -> String {
    let name = savedValue("profileName") ?? ""
    return name.isEmpty ? defaultProfile : name
}

/// Current macOS appearance: `AppleInterfaceStyle` is present ("Dark") in dark mode.
func systemIsDark() -> Bool {
    let out = run("/usr/bin/defaults", ["read", "-g", "AppleInterfaceStyle"])
    return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Whether the app that owns the bundle is running; while it is, it owns the icon.
func orcaIsRunning() -> Bool {
    !run("/usr/bin/pgrep", ["-x", "Orca"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - Orca's artifacts

/// One appearance's artifact and the signature it was composed from.
struct Artifact: Decodable {
    let signature: String
    let file: String
}

/// The settings the artifacts belong to, plus where to find them.
struct Manifest: Decodable {
    let preset: String
    let mode: String
    let themeSource: String
    let appearances: [String: Artifact]
}

func readManifest() -> Manifest? {
    guard let data = try? Data(contentsOf: manifestURL) else { return nil }
    return try? JSONDecoder().decode(Manifest.self, from: data)
}

// MARK: - Bundle writes

/// Re-sign the bundle ad-hoc, preserving its existing entitlements (the get-task-allow entitlement
/// keeps the Web Inspector working after a re-seal).
func reSign(_ appPath: String) {
    let exported = run("/usr/bin/codesign", ["-d", "--entitlements", "-", appPath])
    var arguments = ["--force", "--sign", "-",
                     "--identifier", appBundleID,
                     "--preserve-metadata=entitlements",
                     "-r=designated => identifier \"com.xu.orca\"",
                     appPath]
    if !exported.isEmpty {
        let tmp = "/tmp/orca-icon-sync-entitlements.plist"
        try? exported.write(toFile: tmp, atomically: true, encoding: .utf8)
        arguments.insert(contentsOf: ["--entitlements", tmp], at: 5)
    }
    _ = run("/usr/bin/codesign", arguments)
}

/// Move the bundle's own modification date and re-register it with LaunchServices.
///
/// Measured through `NSWorkspace.icon(forFile:)`, the cache the Dock and Finder draw from: it follows
/// `Contents/Resources/AppIcon.icns` by itself, so this mark is not what makes the new artwork show
/// up. It travels with the file anyway because LaunchServices keys its per-bundle record on it, and
/// nothing but a Dock restart moves the Dock's own snapshot of the tile.
func refreshBundle(_ appPath: String, iconDate: Date?) {
    if let iconDate {
        try? FileManager.default.setAttributes([.modificationDate: iconDate], ofItemAtPath: appPath)
    }
    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    _ = run(lsregister, ["-f", appPath])
}

// MARK: - Reconciliation

/// Install the artifact that matches the Mac's appearance, when one is needed and still current.
///
/// Returns whether the bundle was written.
@discardableResult
func reconcile() -> Bool {
    guard !orcaIsRunning() else { return false }

    let mode = followMode()
    // A fixed icon already sits correctly in the bundle from the last run.
    guard mode == "theme" || mode == "system" else { return false }
    // A pinned page theme paints one plane whatever the Mac does, so there is nothing to follow.
    if mode == "theme", !pageFollowsSystem() { return false }

    guard let manifest = readManifest() else { return false }
    // Stale artifacts belong to settings Orca has already replaced; the next launch will rewrite
    // them, and installing the previous choice in the meantime would be worse than waiting.
    guard manifest.preset == (savedValue("appIconPreset") ?? "orca").lowercased(),
          manifest.mode == mode,
          manifest.themeSource == themeSource()
    else { return false }

    let key = systemIsDark() ? "dark" : "light"
    guard let artifact = manifest.appearances[key] else { return false }

    let app = locateOrcaApp()
    let appPath = app.path
    let source = variantsDirectory.appendingPathComponent(artifact.file)
    let target = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
    guard let incoming = try? Data(contentsOf: source) else { return false }
    if let current = try? Data(contentsOf: target), current == incoming { return false }

    do {
        try incoming.write(to: target, options: .atomic)
    } catch {
        note("write failed: \(error.localizedDescription)")
        return false
    }
    let stamp = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
    reSign(appPath)
    refreshBundle(appPath, iconDate: stamp)
    // The Dock's own tile is deliberately not chased here. Measured with the icon cache in front of
    // it (`NSWorkspace.icon(forFile:)`): IconServices picks the new artwork up from the icon file
    // alone, but the Dock keeps drawing the colour it snapshotted until the Dock restarts — and a
    // restart flashes the whole strip, which costs more than a tile that is one launch behind.
    note("installed \(artifact.file) (\(artifact.signature))")
    return true
}

// MARK: - Watching

/// Re-arm a watcher on a file that editors and the settings UI replace by writing a new one.
final class FileWatch {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    /// Drop and rebuild the source; a replaced inode stops the old one from firing.
    private func arm() {
        source?.cancel()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file may not exist yet; retry on the next reconcile instead of spinning.
            source = nil
            return
        }
        let next = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // `.attrib` covers a plain `touch` (mtime only) — editors that rewrite the file in place
            // may deliver nothing else, and a missed event means a stale icon until the next poll.
            eventMask: [.write, .attrib, .rename, .delete, .extend],
            queue: .main
        )
        next.setEventHandler { [weak self] in
            self?.arm()
            self?.onChange()
        }
        next.setCancelHandler { close(descriptor) }
        next.resume()
        source = next
    }
}

/// Path of the profile patch that carries the page's theme preference.
var themePatchURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".dsh/profiles/\(profileName())/cordis.patch.yml")
}

/// Run once and exit — the LaunchAgent's interval path and manual testing.
func runOnce() {
    reconcile()
    exit(0)
}

/// Strong reference to the live file watcher; a released source stops delivering events.
var themeWatch: FileWatch?

/// Stay resident and react to the system appearance and the page theme preference.
func stayResident() {
    reconcile()

    DistributedNotificationCenter.default.addObserver(
        forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
        object: nil,
        queue: .main
    ) { _ in
        reconcile()
    }

    themeWatch = FileWatch(url: themePatchURL) { reconcile() }

    // Belt and braces: a missed file event, a prefs write that bypassed the file, or the first
    // launch after the profile changed. Cheap enough to keep the icon correct within five minutes.
    Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
        themeWatch = FileWatch(url: themePatchURL) { reconcile() }
        reconcile()
    }

    RunLoop.main.run()
}

if CommandLine.arguments.contains("--once") {
    runOnce()
} else {
    stayResident()
}
