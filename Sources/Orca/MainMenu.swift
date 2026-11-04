import AppKit

/// Builds the application menu bar for the single Orca window.
///
/// Every title comes from the shell's copy table, so switching the language rebuilds this menu
/// rather than leaving half of it in the previous one.
enum MainMenu {
    static func install(appDelegate: AppDelegate, window: MainWindowController, copy: ShellCopy) {
        let mainMenu = NSMenu()

        mainMenu.addItem(applicationMenu(appDelegate, copy))
        mainMenu.addItem(fileMenu(window, copy))
        mainMenu.addItem(editMenu(copy))
        mainMenu.addItem(viewMenu(window, copy))
        mainMenu.addItem(serviceMenu(window, appDelegate, copy))
        mainMenu.addItem(windowMenu(copy))
        mainMenu.addItem(helpMenu(appDelegate, copy))

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menus

    private static func applicationMenu(_ delegate: AppDelegate, _ copy: ShellCopy) -> NSMenuItem {
        let menu = NSMenu(title: "Orca")
        menu.add(title: copy.menu.about, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        menu.addItem(.separator())
        // ⌘, is the page's own settings surface; the shell's panel (service port, profile, command)
        // sits one modifier further out so both are reachable without a conflict.
        menu.add(
            title: copy.menu.settings,
            action: #selector(AppDelegate.showSettings(_:)),
            key: ",",
            target: delegate,
            modifiers: [.command, .option]
        )
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: copy.menu.services, action: nil, keyEquivalent: "")
        let services = NSMenu(title: copy.menu.services)
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.add(title: copy.menu.hide, action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        menu.add(
            title: copy.menu.hideOthers,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            target: NSApp,
            modifiers: [.command, .option]
        )
        menu.add(title: copy.menu.showAll, action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        menu.addItem(.separator())
        menu.add(title: copy.menu.quit, action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        return wrap(menu, title: "Orca")
    }

    private static func fileMenu(_ window: MainWindowController, _ copy: ShellCopy) -> NSMenuItem {
        let menu = NSMenu(title: copy.menu.file)
        menu.add(title: copy.menu.closeWindow, action: #selector(NSWindow.performClose(_:)), key: "w", target: nil)
        menu.addItem(.separator())
        menu.add(
            title: copy.menu.openInBrowser,
            action: #selector(MainWindowController.openInBrowser(_:)),
            key: "o",
            target: window,
            modifiers: [.command, .shift]
        )
        menu.add(
            title: copy.menu.copyAccessLink,
            action: #selector(MainWindowController.copyAccessLink(_:)),
            target: window
        )
        return wrap(menu, title: copy.menu.file)
    }

    private static func editMenu(_ copy: ShellCopy) -> NSMenuItem {
        let menu = NSMenu(title: copy.menu.edit)
        menu.add(title: copy.menu.undo, action: NSSelectorFromString("undo:"), key: "z")
        menu.add(title: copy.menu.redo, action: NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        menu.add(title: copy.menu.cut, action: NSSelectorFromString("cut:"), key: "x")
        menu.add(title: copy.menu.copy, action: NSSelectorFromString("copy:"), key: "c")
        menu.add(title: copy.menu.paste, action: NSSelectorFromString("paste:"), key: "v")
        menu.add(title: copy.menu.selectAll, action: NSSelectorFromString("selectAll:"), key: "a")
        return wrap(menu, title: copy.menu.edit)
    }

    private static func viewMenu(_ window: MainWindowController, _ copy: ShellCopy) -> NSMenuItem {
        let menu = NSMenu(title: copy.menu.view)
        menu.add(title: copy.menu.reload, action: #selector(MainWindowController.reloadPage(_:)), key: "r", target: window)
        menu.add(
            title: copy.menu.reloadFromServer,
            action: #selector(MainWindowController.reloadFromOrigin(_:)),
            key: "r",
            target: window,
            modifiers: [.command, .option]
        )
        menu.addItem(.separator())
        menu.add(title: copy.menu.actualSize, action: #selector(MainWindowController.actualSize(_:)), key: "0", target: window)
        menu.add(title: copy.menu.zoomIn, action: #selector(MainWindowController.zoomIn(_:)), key: "+", target: window)
        menu.add(title: copy.menu.zoomOut, action: #selector(MainWindowController.zoomOut(_:)), key: "-", target: window)
        menu.addItem(.separator())
        menu.add(
            title: copy.menu.enterFullScreen,
            action: #selector(NSWindow.toggleFullScreen(_:)),
            key: "f",
            target: nil,
            modifiers: [.command, .control]
        )
        // Dev-tools shortcuts (F12, ⌥⌘I, ⌘⇧C) are owned solely by InspectorController's local key
        // monitor, which must swallow the key before the page sees it. Do NOT give these menu items a
        // keyEquivalent — a second binding would call selectElement()/toggle() twice per press and
        // make the picker or inspector flicker on then straight back off.
        menu.add(
            title: copy.menu.developerTools,
            action: #selector(MainWindowController.toggleDevTools(_:)),
            target: window
        )
        menu.add(
            title: copy.menu.selectElement,
            action: #selector(MainWindowController.selectElementForInspection(_:)),
            target: window
        )
        menu.add(
            title: copy.menu.showConsole,
            action: #selector(MainWindowController.showInspectorConsole(_:)),
            target: window
        )
        return wrap(menu, title: copy.menu.view)
    }

    private static func serviceMenu(
        _ window: MainWindowController,
        _ delegate: AppDelegate,
        _ copy: ShellCopy
    ) -> NSMenuItem {
        let menu = NSMenu(title: copy.menu.service)
        menu.add(
            title: copy.menu.restartService,
            action: #selector(MainWindowController.restartService(_:)),
            key: "r",
            target: window,
            modifiers: [.command, .shift]
        )
        menu.add(title: copy.menu.stopService, action: #selector(MainWindowController.stopService(_:)), target: window)
        menu.addItem(.separator())
        menu.add(title: copy.menu.showServiceLog, action: #selector(MainWindowController.openServiceLog(_:)), target: window)
        menu.addItem(.separator())
        // dsh-superagent is a second dsh profile with its own service, so it has its own window
        // rather than a second tab: the shell only reads its access URL from that service's log.
        menu.add(
            title: copy.menu.superagent,
            action: #selector(AppDelegate.showSuperagent(_:)),
            key: "s",
            target: delegate,
            modifiers: [.command, .shift]
        )
        return wrap(menu, title: copy.menu.service)
    }

    private static func windowMenu(_ copy: ShellCopy) -> NSMenuItem {
        let menu = NSMenu(title: copy.menu.window)
        menu.add(title: copy.menu.minimize, action: #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil)
        menu.add(title: copy.menu.zoom, action: #selector(NSWindow.performZoom(_:)), target: nil)
        menu.addItem(.separator())
        menu.add(title: copy.menu.bringAllToFront, action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = menu
        return wrap(menu, title: copy.menu.window)
    }

    private static func helpMenu(_ delegate: AppDelegate, _ copy: ShellCopy) -> NSMenuItem {
        let menu = NSMenu(title: copy.menu.help)
        menu.add(
            title: copy.menu.projectPage,
            action: #selector(AppDelegate.openProjectPage(_:)),
            target: delegate
        )
        return wrap(menu, title: copy.menu.help)
    }

    // MARK: - Helpers

    private static func wrap(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

private extension NSMenu {
    @discardableResult
    func add(
        title: String,
        action: Selector?,
        key: String = "",
        target: AnyObject? = nil,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        addItem(item)
        return item
    }
}
