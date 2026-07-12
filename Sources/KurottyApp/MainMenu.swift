import AppKit

enum MainMenu {
    @MainActor
    static func install(target: AppDelegate) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = AppConstants.Bundle.displayName
        let appMenu = NSMenu(title: AppConstants.Bundle.displayName)
        appMenu.addItem(NSMenuItem(title: AppLocalization.format(.about, AppConstants.Bundle.displayName), action: #selector(AppDelegate.showAboutPanel), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let checkForUpdates = NSMenuItem(title: AppLocalization.string(.checkForUpdates), action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = target
        appMenu.addItem(checkForUpdates)
        appMenu.addItem(NSMenuItem(title: AppLocalization.string(.settings), action: #selector(AppDelegate.openPreferences), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: AppLocalization.format(.quit, AppConstants.Bundle.displayName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: AppLocalization.string(.shell))
        fileMenu.addItem(NSMenuItem(title: AppLocalization.string(.newWindow), action: #selector(AppDelegate.openNewWindow), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: AppLocalization.string(.newTab), action: #selector(AppDelegate.newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: AppLocalization.string(.closePaneOrTab), action: #selector(AppDelegate.closeCurrentPane), keyEquivalent: "w"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: AppLocalization.string(.splitVertically), action: #selector(AppDelegate.splitVertically), keyEquivalent: "d"))
        let horizontal = NSMenuItem(title: AppLocalization.string(.splitHorizontally), action: #selector(AppDelegate.splitHorizontally), keyEquivalent: "D")
        horizontal.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(horizontal)
        fileMenu.addItem(.separator())
        let previousTab = NSMenuItem(title: AppLocalization.string(.previousTab), action: #selector(AppDelegate.selectPreviousTab), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(previousTab)
        let nextTab = NSMenuItem(title: AppLocalization.string(.nextTab), action: #selector(AppDelegate.selectNextTab), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(nextTab)
        fileMenu.addItem(.separator())
        let commandPalette = NSMenuItem(title: AppLocalization.string(.commandPalette) + "...", action: #selector(AppDelegate.openCommandPalette), keyEquivalent: "P")
        commandPalette.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(commandPalette)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let languageMenuItem = NSMenuItem()
        let languageMenu = NSMenu(title: AppLocalization.string(.language))
        let languageOptions: [(AppLanguagePreference, L10nKey)] = [
            (.system, .systemDefault), (.english, .english), (.korean, .korean), (.japanese, .japanese),
        ]
        for (preference, titleKey) in languageOptions {
            let item = NSMenuItem(title: AppLocalization.string(titleKey), action: #selector(AppDelegate.changeLanguage(_:)), keyEquivalent: "")
            item.representedObject = preference.rawValue
            item.state = AppLocalization.preference == preference ? .on : .off
            languageMenu.addItem(item)
        }
        languageMenuItem.submenu = languageMenu
        mainMenu.addItem(languageMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: AppLocalization.string(.edit))
        let cut = NSMenuItem(title: AppLocalization.string(.cut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cut.target = nil
        let copy = NSMenuItem(title: AppLocalization.string(.copy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.target = nil
        let paste = NSMenuItem(title: AppLocalization.string(.paste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.target = nil
        editMenu.addItem(cut)
        editMenu.addItem(copy)
        editMenu.addItem(paste)
        editMenuItem.submenu = editMenu
        editMenuItem.isHidden = true
        mainMenu.addItem(editMenuItem)

        for item in mainMenu.items {
            item.target = target
            guard item.submenu !== editMenu else { continue }
            item.submenu?.items.forEach { $0.target = target }
        }

        NSApp.mainMenu = mainMenu
    }
}
