import AppKit

/// Builds the application menu bar for the single Orca window.
enum MainMenu {
    static func install(appDelegate: AppDelegate, window: MainWindowController) {
        let mainMenu = NSMenu()

        mainMenu.addItem(applicationMenu(appDelegate))
        mainMenu.addItem(fileMenu(window))
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu(window))
        mainMenu.addItem(serviceMenu(window))
        mainMenu.addItem(windowMenu())
        mainMenu.addItem(helpMenu(appDelegate))

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menus

    private static func applicationMenu(_ delegate: AppDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "Orca")
        menu.add(title: "About Orca", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        menu.addItem(.separator())
        // ⌘, is the page's own settings surface; the shell's panel (service port, profile, command)
        // sits one modifier further out so both are reachable without a conflict.
        menu.add(
            title: "Orca Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            key: ",",
            target: delegate,
            modifiers: [.command, .option]
        )
        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.add(title: "Hide Orca", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        menu.add(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            target: NSApp,
            modifiers: [.command, .option]
        )
        menu.add(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        menu.addItem(.separator())
        menu.add(title: "Quit Orca", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        return wrap(menu, title: "Orca")
    }

    private static func fileMenu(_ window: MainWindowController) -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.add(title: "Close Window", action: #selector(NSWindow.performClose(_:)), key: "w", target: nil)
        menu.addItem(.separator())
        menu.add(
            title: "Open in Browser",
            action: #selector(MainWindowController.openInBrowser(_:)),
            key: "o",
            target: window,
            modifiers: [.command, .shift]
        )
        menu.add(
            title: "Copy Access Link",
            action: #selector(MainWindowController.copyAccessLink(_:)),
            target: window
        )
        return wrap(menu, title: "File")
    }

    private static func editMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.add(title: "Undo", action: NSSelectorFromString("undo:"), key: "z")
        menu.add(title: "Redo", action: NSSelectorFromString("redo:"), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        menu.add(title: "Cut", action: NSSelectorFromString("cut:"), key: "x")
        menu.add(title: "Copy", action: NSSelectorFromString("copy:"), key: "c")
        menu.add(title: "Paste", action: NSSelectorFromString("paste:"), key: "v")
        menu.add(title: "Select All", action: NSSelectorFromString("selectAll:"), key: "a")
        return wrap(menu, title: "Edit")
    }

    private static func viewMenu(_ window: MainWindowController) -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.add(title: "Reload", action: #selector(MainWindowController.reloadPage(_:)), key: "r", target: window)
        menu.add(
            title: "Reload from Server",
            action: #selector(MainWindowController.reloadFromOrigin(_:)),
            key: "r",
            target: window,
            modifiers: [.command, .option]
        )
        menu.addItem(.separator())
        menu.add(title: "Actual Size", action: #selector(MainWindowController.actualSize(_:)), key: "0", target: window)
        menu.add(title: "Zoom In", action: #selector(MainWindowController.zoomIn(_:)), key: "+", target: window)
        menu.add(title: "Zoom Out", action: #selector(MainWindowController.zoomOut(_:)), key: "-", target: window)
        menu.addItem(.separator())
        menu.add(
            title: "Enter Full Screen",
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
            title: "Developer Tools",
            action: #selector(MainWindowController.toggleDevTools(_:)),
            target: window
        )
        menu.add(
            title: "Select Element for Inspection",
            action: #selector(MainWindowController.selectElementForInspection(_:)),
            target: window
        )
        menu.add(
            title: "Show Console",
            action: #selector(MainWindowController.showInspectorConsole(_:)),
            target: window
        )
        return wrap(menu, title: "View")
    }

    private static func serviceMenu(_ window: MainWindowController) -> NSMenuItem {
        let menu = NSMenu(title: "Service")
        menu.add(
            title: "Restart Local Service",
            action: #selector(MainWindowController.restartService(_:)),
            key: "r",
            target: window,
            modifiers: [.command, .shift]
        )
        menu.add(title: "Stop Local Service", action: #selector(MainWindowController.stopService(_:)), target: window)
        menu.addItem(.separator())
        menu.add(title: "Show Service Log", action: #selector(MainWindowController.openServiceLog(_:)), target: window)
        return wrap(menu, title: "Service")
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.add(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil)
        menu.add(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), target: nil)
        menu.addItem(.separator())
        menu.add(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = menu
        return wrap(menu, title: "Window")
    }

    private static func helpMenu(_ delegate: AppDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "Help")
        menu.add(
            title: "DeepSeek Harness on GitHub",
            action: #selector(AppDelegate.openProjectPage(_:)),
            target: delegate
        )
        return wrap(menu, title: "Help")
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
