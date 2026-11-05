import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.activate()
        buildMenu()
        NotificationCenter.default.addObserver(forName: .languageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.buildMenu()
        }
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard OpenDocuments.hasUnsavedWork else { return .terminateNow }
        OpenDocuments.confirmQuit { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Every window is independent: its own panels, connections and transfer queue.
    @objc func newWindow(_ sender: Any?) {
        let controller = MainWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.showWindow(nil)
    }

    @objc private func showHelp(_ sender: Any?) { HelpWindowController.show() }
    @objc private func biggerText(_ sender: Any?) { AppFont.size += 1 }
    @objc private func smallerText(_ sender: Any?) { AppFont.size -= 1 }
    @objc private func defaultText(_ sender: Any?) { AppFont.size = AppFont.defaultSize }
    @objc private func chooseFont(_ sender: NSMenuItem) {
        if let family = sender.representedObject as? String { AppFont.family = family }
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String, let choice = Theme.Choice(rawValue: name) { Theme.choice = choice }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { L10n.language = code }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseLanguage(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == L10n.language ? .on : .off
        }
        if menuItem.action == #selector(chooseTheme(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == Theme.choice.rawValue ? .on : .off
        }
        if menuItem.action == #selector(chooseFont(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == AppFont.family ? .on : .off
        }
        return true
    }

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func buildMenu() {
        let t = L10n.t
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item(t("menu.about", []), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item(t("menu.hide", []), #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item(t("menu.quit", []), #selector(NSApplication.terminate(_:)), "q"))

        let fileMenu = NSMenu(title: t("menu.file", []))
        fileMenu.addItem(item(t("menu.newWindow", []), #selector(newWindow(_:)), "n", target: self))
        fileMenu.addItem(item(t("menu.sites", []), #selector(MainWindowController.showSiteManager(_:)), "k"))
        fileMenu.addItem(item(t("menu.search", []), #selector(MainWindowController.showSearch(_:)), "f"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(t("menu.close", []), #selector(NSWindow.performClose(_:)), "w"))

        // Text fields in the site manager need these for copy and paste.
        let editMenu = NSMenu(title: t("menu.edit", []))
        editMenu.addItem(item(t("menu.undo", []), Selector(("undo:")), "z"))
        editMenu.addItem(item(t("menu.redo", []), Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item(t("menu.cut", []), #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item(t("menu.copy", []), #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item(t("menu.paste", []), #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item(t("menu.selectAll", []), #selector(NSText.selectAll(_:)), "a"))

        let viewMenu = NSMenu(title: t("menu.view", []))
        viewMenu.addItem(item(t("menu.hidden", []), #selector(MainWindowController.toggleHiddenFiles(_:)), ".", [.command, .shift]))
        viewMenu.addItem(item(t("menu.attributes", []), #selector(MainWindowController.toggleAttributes(_:)), "a", [.command, .shift]))
        viewMenu.addItem(item(t("menu.refresh", []), #selector(MainWindowController.refreshPanels(_:)), "r"))
        viewMenu.addItem(item(t("menu.terminalPane", []), #selector(MainWindowController.toggleTerminalPane(_:)), "j"))

        viewMenu.addItem(item(t("menu.sshList", []), #selector(MainWindowController.showSSHMenu(_:)), String(UnicodeScalar(NSF9FunctionKey)!), .option))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item(t("menu.textBigger", []), #selector(biggerText(_:)), "+", target: self))
        // Layouts where + needs Shift send = with Command.
        let biggerAlternate = item(t("menu.textBigger", []), #selector(biggerText(_:)), "=", target: self)
        biggerAlternate.isHidden = true
        biggerAlternate.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(biggerAlternate)
        viewMenu.addItem(item(t("menu.textSmaller", []), #selector(smallerText(_:)), "-", target: self))
        viewMenu.addItem(item(t("menu.textDefault", []), #selector(defaultText(_:)), "0", target: self))
        let fontMenu = NSMenu(title: t("menu.font", []))
        for family in AppFont.families {
            let title = family == AppFont.systemFamily ? t("menu.fontSystem", []) : family
            let entry = item(title, #selector(chooseFont(_:)), target: self)
            entry.representedObject = family
            fontMenu.addItem(entry)
        }
        let fontHolder = NSMenuItem(title: t("menu.font", []), action: nil, keyEquivalent: "")
        fontHolder.submenu = fontMenu
        viewMenu.addItem(fontHolder)
        let themeMenu = NSMenu(title: t("menu.theme", []))
        for choice in Theme.Choice.allCases {
            let entry = item(t(choice.titleKey, []), #selector(chooseTheme(_:)), target: self)
            entry.representedObject = choice.rawValue
            themeMenu.addItem(entry)
        }
        let themeHolder = NSMenuItem(title: t("menu.theme", []), action: nil, keyEquivalent: "")
        themeHolder.submenu = themeMenu
        viewMenu.addItem(themeHolder)

        let languageMenu = NSMenu(title: t("menu.language", []))
        for language in L10n.available {
            let entry = item(language.name, #selector(chooseLanguage(_:)), target: self)
            entry.representedObject = language.code
            languageMenu.addItem(entry)
        }

        let helpMenu = NSMenu(title: t("menu.help", []))
        let f1 = String(UnicodeScalar(NSF1FunctionKey)!)
        helpMenu.addItem(item(t("menu.helpItem", []), #selector(showHelp(_:)), f1, .option, target: self))
        // Option with a brightness key opens Displays unless Fn is held, so this one always works.
        let helpAlternate = item(t("menu.helpItem", []), #selector(showHelp(_:)), "?", target: self)
        helpAlternate.isHidden = true
        helpAlternate.allowsKeyEquivalentWhenHidden = true
        helpMenu.addItem(helpAlternate)

        for submenu in [appMenu, fileMenu, editMenu, viewMenu, languageMenu, helpMenu] {
            let holder = NSMenuItem()
            holder.submenu = submenu
            main.addItem(holder)
        }
        NSApp.mainMenu = main
        NSApp.helpMenu = helpMenu
    }
}
