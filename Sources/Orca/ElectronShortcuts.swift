import AppKit
import Carbon.HIToolbox

/// How an Electron default accelerator maps onto the current shell.
enum ElectronShortcutCoverage {
    /// Orca performs the action with the same combination.
    case covered
    /// Orca performs the action, but the Electron combination belongs to another Orca action.
    case conflict
    /// No Orca action exists yet; recorded for parity, with no native registration.
    case missing
}

/// One application-menu accelerator from Electron's default menu.
struct ElectronShortcut {
    let slot: HotkeySlot
    let label: String
    let binding: HotkeyBinding
    let coverage: ElectronShortcutCoverage
}

/// Electron's default application-menu accelerators, recorded for parity.
///
/// These are menu accelerators rather than global hotkeys: covered entries already belong to
/// Orca's menu and responder chain, so they are never registered as empty keys. Only `missing`
/// entries become while-active placeholders, and the conflicting one stays with Orca's action.
enum ElectronDefaults {
    static let shortcuts: [ElectronShortcut] = [
        entry("hide", "Hide Orca", kVK_ANSI_H, [.command], .covered),
        entry("hideOthers", "Hide Others", kVK_ANSI_H, [.command, .option], .covered),
        entry("quit", "Quit Orca", kVK_ANSI_Q, [.command], .covered),
        entry("close", "Close Window", kVK_ANSI_W, [.command], .covered),
        entry("undo", "Undo", kVK_ANSI_Z, [.command], .covered),
        entry("redo", "Redo", kVK_ANSI_Z, [.command, .shift], .covered),
        entry("cut", "Cut", kVK_ANSI_X, [.command], .covered),
        entry("copy", "Copy", kVK_ANSI_C, [.command], .covered),
        entry("paste", "Paste", kVK_ANSI_V, [.command], .covered),
        // No command yet; DSH's desktop shortcut editor can record it without a native claim.
        entry("pasteAndMatchStyle", "Paste and Match Style", kVK_ANSI_V, [.command, .option, .shift], .missing),
        entry("selectAll", "Select All", kVK_ANSI_A, [.command], .covered),
        entry("reload", "Reload", kVK_ANSI_R, [.command], .covered),
        // Orca reloads from the server with ⌥⌘R; ⇧⌘R already restarts the local service.
        entry("forceReload", "Force Reload", kVK_ANSI_R, [.command, .shift], .conflict),
        // Orca's own developer tools, on the Electron default's F12 rather than its ⌥⌘I; that
        // combination still works and keeps the entry honest about what the key does.
        entry("toggleDevTools", "Developer Tools", kVK_F12, [], .covered),
        entry("actualSize", "Actual Size", kVK_ANSI_0, [.command], .covered),
        entry("zoomIn", "Zoom In", kVK_ANSI_Equal, [.command, .shift], .covered),
        entry("zoomOut", "Zoom Out", kVK_ANSI_Minus, [.command], .covered),
        entry("toggleFullScreen", "Toggle Full Screen", kVK_ANSI_F, [.command, .control], .covered),
        entry("minimize", "Minimize", kVK_ANSI_M, [.command], .covered),
    ]

    private static func entry(
        _ id: String,
        _ label: String,
        _ keyCode: Int,
        _ modifiers: NSEvent.ModifierFlags,
        _ coverage: ElectronShortcutCoverage
    ) -> ElectronShortcut {
        ElectronShortcut(
            slot: HotkeySlot("electron.\(id)"),
            label: label,
            binding: HotkeyBinding(keyCode: UInt32(keyCode), modifiers: modifiers),
            coverage: coverage
        )
    }
}
