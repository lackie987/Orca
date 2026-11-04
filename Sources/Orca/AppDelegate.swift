import AppKit

/// Application lifecycle: window creation, menu installation and service ownership.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private lazy var hotkeys = GlobalHotkeyCenter.shared
    private var service: ServiceController!
    private var windowController: MainWindowController!
    private var settingsController: SettingsWindowController?
    /// The panel of the separate dsh-superagent service; built on first use and kept so the window
    /// keeps its page, its cookies and its scroll position between openings.
    private var superagentController: SuperagentWindowController?
    /// Re-tints the icon when the Mac itself switches appearance, while Orca stays open.
    private var appearanceObserver: NSObjectProtocol?
    /// Set while the termination sequence is in flight, so a second request is not answered twice.
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        service = ServiceController(preferences: preferences)
        windowController = MainWindowController(service: service, preferences: preferences)
        MainMenu.install(appDelegate: self, window: windowController, copy: preferences.copy)

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
            guard let self else { return }
            // Two ways the Mac's own switch moves the icon: `system` mode paints from the icon's
            // planes, and `theme` mode paints from the page — but a page whose theme source is
            // `system` only flips when its own repaint lands, which can be late or never while the
            // window is not drawing. Re-resolving here covers both, from the side's remembered base.
            let followsMac = AppIcon.followsSystemAppearance(self.preferences)
                || (AppIcon.followsTheme(self.preferences) && AppIcon.pageFollowsSystem(self.preferences))
            guard followsMac else { return }
            AppIconInstaller.applyCurrent(self.preferences, forApp: Bundle.main.bundlePath)
            // The page asked for nothing here: the Mac flipped. Tell the settings row so its
            // preview follows the Dock instead of waiting for the next read.
            self.windowController.pushAppIconState()
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

    /// Quits only once the outstanding work is done, without blocking the main thread while it runs.
    ///
    /// The old path did both pieces synchronously inside `applicationWillTerminate`: a `codesign` run
    /// with no timeout, then a two-second wait for the child process. AppKit was frozen for that whole
    /// stretch, and macOS kills an app whose termination does not answer — which could interrupt a
    /// signature halfway and leave the installed bundle unlaunchable. Answering `.terminateLater` and
    /// replying when both are finished keeps the reply truthful and the thread free.
    ///
    /// The page is asked first, for the same reason the window close asks it: ⌘Q is native, so the
    /// guard cannot see it, and quitting is the most destructive version of the same mistake.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true
        guard let windowController else {
            performTermination()
            return .terminateLater
        }
        windowController.confirmTermination { [weak self] proceed in
            guard let self else { return }
            guard proceed else {
                // Nothing has been touched yet, so cancelling is exact.
                self.isTerminating = false
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            self.performTermination()
        }
        return .terminateLater
    }

    /// The quit sequence proper: release the shell's hooks, seal the bundle, stop the service, reply.
    private func performTermination() {
        if let appearanceObserver {
            DistributedNotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        hotkeys.unregisterAll()
        // An icon written moments before quitting still owes the bundle its signature; the queued one
        // would die with the process and leave the installed app sealed against the old icon.
        AppBundleSeal.flush(for: Bundle.main.bundlePath) { [weak self] in
            guard let self else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            self.service.shutdown {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
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
            controller.onLanguageChange = { [weak self] in
                self?.reloadShellCopy()
            }
            settingsController = controller
        }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Rebuilds the surfaces the shell draws itself in the new language; the page keeps its own.
    private func reloadShellCopy() {
        MainMenu.install(appDelegate: self, window: windowController, copy: preferences.copy)
        windowController.refreshShellCopy()
    }

    /// Opens the dsh-superagent panel, a service this shell does not boot.
    @objc func showSuperagent(_ sender: Any?) {
        if superagentController == nil {
            superagentController = SuperagentWindowController()
        }
        superagentController?.present()
    }

    @objc func openProjectPage(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/deepseek-ai/deepseek-harness") else { return }
        NSWorkspace.shared.open(url)
    }
}
