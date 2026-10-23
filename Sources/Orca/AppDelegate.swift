import AppKit

/// Application lifecycle: window creation, menu installation and service ownership.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private var service: ServiceController!
    private var windowController: MainWindowController!
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = ServiceController(preferences: preferences)
        windowController = MainWindowController(service: service, preferences: preferences)
        windowController.onRequestSettings = { [weak self] in
            self?.showSettings(nil)
        }
        MainMenu.install(appDelegate: self, window: windowController)

        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        service.start()

        #if DEBUG
        if ProcessInfo.processInfo.environment["ORCA_SHOW_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings(nil)
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.present()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

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
