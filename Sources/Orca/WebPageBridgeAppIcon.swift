import AppKit
import UniformTypeIdentifiers
import WebKit

/// The bridge behind the Dock icon: the preset the page picks, the previews its settings row draws,
/// and the picture it hands over when the preset is `custom`.
///
/// The composition itself lives in `AppIcon` and `AppIconInstaller`; this file is the wire between
/// the page and them, plus the one place an icon choice is validated before it is stored.
extension WebPageController {
    /// Reads and writes the app-icon choice; the `dsh-app-icon` plugin drives this.
    ///
    /// `get` reports the saved preset and whether it follows the Mac's appearance. `preset` picks a
    /// built-in icon, `follow` toggles system-following for the themed three, `variant` is accepted
    /// for older pages but no longer re-tints anything, `set` opens the image picker for a custom
    /// picture and `reset` returns to the initial `orca` icon. Every write replies with the state it
    /// accepted, so the page never has to assume its write landed. The `.app` write is bundle
    /// metadata, so it survives updates.
    func handleAppIconMessage(_ message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let payload = message.body as? [String: Any],
              let kind = payload["kind"] as? String else {
            replyHandler(nil, "Malformed orcaAppIcon message")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                replyHandler(nil, "Orca is shutting down")
                return
            }
            switch kind {
            case "get":
                replyHandler(self.iconState(), nil)
            case "preset":
                guard let preset = payload["preset"] as? String, AppIcon.presets.contains(preset) else {
                    replyHandler(self.iconState(), nil)
                    return
                }
                self.preferences.appIconPreset = preset
                self.reapplyIcon()
                replyHandler(self.iconState(), nil)
            case "follow":
                let flag = (payload["follow"] as? Bool)
                    ?? (payload["follow"] as? NSNumber)?.boolValue
                    ?? false
                self.preferences.appIconFollowsTheme = flag
                self.reapplyIcon()
                replyHandler(self.iconState(), nil)
            case "variant":
                guard let variant = payload["variant"] as? String, AppIcon.themed.contains(variant) else {
                    replyHandler(self.iconState(), nil)
                    return
                }
                self.preferences.appIconThemeVariant = variant
                // Theme mode is the only place a page variant may move the icon; system mode uses
                // the Mac and none keeps the chosen artwork.
                if AppIcon.followsTheme(self.preferences),
                   AppIcon.themed.contains(self.preferences.appIconPreset) {
                    self.reapplyIcon()
                }
                replyHandler(self.iconState(), nil)
            case "followMode":
                guard let raw = payload["mode"] as? String,
                      let mode = AppIcon.FollowMode(rawValue: raw)
                else {
                    replyHandler(self.iconState(), nil)
                    return
                }
                self.preferences.appIconFollowMode = mode.rawValue
                self.reapplyIcon()
                replyHandler(self.iconState(), nil)
            case "reset":
                self.preferences.appIconPreset = "orca"
                self.reapplyIcon()
                replyHandler(self.iconState(), nil)
            case "template":
                // The colour well always posts `#rrggbb`; anything else keeps the stored colour.
                if let raw = payload["color"] as? String,
                   let color = ColorHex.color(raw.lowercased()),
                   let hex = ColorHex.string(color) {
                    self.preferences.appIconTemplateColor = hex
                }
                self.preferences.appIconPreset = "template"
                self.reapplyIcon()
                replyHandler(self.iconState(), nil)
            case "templateFollow":
                let flag = (payload["follow"] as? Bool)
                    ?? (payload["follow"] as? NSNumber)?.boolValue
                    ?? false
                self.preferences.appIconTemplateFollowsTheme = flag
                if self.preferences.appIconPreset == "template" {
                    self.reapplyIcon()
                }
                replyHandler(self.iconState(), nil)
            case "set":
                self.pickCustomIcon(replyHandler: replyHandler)
            case "previews":
                replyHandler(
                    AppIcon.previews(only: payload["only"] as? String),
                    nil
                )
            default:
                replyHandler(nil, "Unknown orcaAppIcon kind: \(kind)")
            }
        }
    }

    /// Snapshot the page reads back after every write.
    ///
    /// `templateBackground` is the plane the icon actually uses right now; the settings row draws
    /// its preview with that instead of re-deriving the colour from the page theme.
    /// `displayVariant` is the artwork the themed presets currently resolve to. `followMode` and
    /// `followCapable` drive the tri-state switcher.
    func iconState() -> [String: Any] {
        let background = AppIcon.templateColorHex(preferences)
        return [
            "preset": preferences.appIconPreset,
            "follow": preferences.appIconFollowsTheme,
            "followMode": AppIcon.followMode(preferences).rawValue,
            "followCapable": AppIcon.canFollow(preferences),
            "displayVariant": AppIcon.displayVariant(preferences),
            "templateColor": AppIcon.storedTemplateColorHex(preferences),
            "templateBackground": background,
            "templateFollow": preferences.appIconTemplateFollowsTheme,
            "systemAppearance": AppIcon.systemIsDark ? "dark" : "light",
        ]
    }

    /// Applies whatever the saved preset resolves to (Dock, Finder and the bundle's icon file).
    func reapplyIcon() {
        AppIconInstaller.applyCurrent(preferences, forApp: Bundle.main.bundlePath)
    }

    /// Opens the image picker, composes the choice and switches the preset to `custom`.
    func pickCustomIcon(replyHandler: @escaping (Any?, String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "选择"
        panel.message = "选择一张图片作为 Orca 的应用图标"
        present(panel) { [weak self] response in
            guard let self else {
                replyHandler(nil, "Orca is shutting down")
                return
            }
            guard response == .OK, let url = panel.url else {
                // A cancelled/empty selection must resolve to `null` in JS (not `undefined`):
                // WebKit serialises a `nil` reply as `undefined`, which leaks into the caller.
                replyHandler(NSNull(), nil)
                return
            }
            guard let image = NSImage(contentsOf: url) else {
                replyHandler(nil, "无法读取这张图片")
                return
            }
            guard AppIconInstaller.installCustom(
                image, at: AppPaths.customAppIcon, forApp: Bundle.main.bundlePath
            ) != nil else {
                replyHandler(nil, "处理或写入应用图标失败（应用目录可能不可写）")
                return
            }
            self.preferences.appIconPreset = "custom"
            self.preferences.customAppIconPath = AppPaths.customAppIcon.path
            replyHandler(self.iconState(), nil)
        }
    }
}
