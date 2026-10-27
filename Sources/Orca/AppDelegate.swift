import AppKit

/// Application lifecycle: window creation, menu installation and service ownership.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private lazy var hotkeys = GlobalHotkeyCenter.shared
    private var service: ServiceController!
    private var windowController: MainWindowController!
    private var settingsController: SettingsWindowController?
    /// Re-tints the icon when the Mac itself switches appearance, while Orca stays open.
    private var appearanceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = ServiceController(preferences: preferences)
        windowController = MainWindowController(service: service, preferences: preferences)
        MainMenu.install(appDelegate: self, window: windowController)

        // The Carbon surface is ready, but no slot is bound: DSH's desktop shortcut service
        // records and owns these combinations, and a native placeholder would intercept them.
        hotkeys.prepare()

        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // In system mode the icon's light/dark plane follows the Mac, not the page theme. The shell
        // pins `NSApp.appearance` to the web theme, so AppKit's appearance KVO would answer the
        // page; the distributed system notification is the one that answers the machine.
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, AppIcon.followsSystemAppearance(self.preferences) else { return }
            AppIconInstaller.applyCurrent(self.preferences, forApp: Bundle.main.bundlePath)
        }

        // Resolve the saved preset into the bundle's icon file too, not just the Dock tile: that
        // file is what Finder, the next launch and the startup surface read, so leaving it behind
        // is what made a chosen icon look like it had never been saved.
        AppIconInstaller.applyCurrent(preferences, forApp: Bundle.main.bundlePath)

        service.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // AppKit may deliver this before applicationDidFinishLaunching has built the window
        // (a reopen/relaunch Apple event arriving during early launch), so the implicitly-unwrapped
        // controller must be checked rather than force-unwrapped — otherwise the trap above fires.
        // When it is still nil the launch path shows the window on its own.
        windowController?.present()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        hotkeys.applicationActivated()
        // Activation reloads the bundle icon, which can undo the tile set earlier; re-assert the
        // saved choice so the Dock keeps showing it for the whole session.
        AppIconInstaller.refreshDock(preferences)
    }

    func applicationWillResignActive(_ notification: Notification) {
        hotkeys.applicationDeactivated()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appearanceObserver {
            DistributedNotificationCenter.default.removeObserver(appearanceObserver)
        }
        hotkeys.unregisterAll()
        // An icon written moments before quitting still owes the bundle its signature; the queued
        // one would die with the process and leave the installed app sealed against the old icon.
        AppBundleSeal.flush(for: Bundle.main.bundlePath)
        service.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Opens the shell's own settings panel: the service parameters, which the page cannot see.
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            let controller = SettingsWindowController(preferences: preferences)
            controller.onSave = { [weak self] needsRestart in
                guard let self else { return }
                self.windowController.applyPreferences()
                if needsRestart {
                    self.service.restart()
                }
            }
            settingsController = controller
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openProjectPage(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/deepseek-ai/deepseek-harness") else { return }
        NSWorkspace.shared.open(url)
    }
}
