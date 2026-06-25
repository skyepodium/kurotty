import AppKit

enum MainMenu {
    @MainActor
    static func install(target: AppDelegate) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = AppConstants.Bundle.displayName
        let appMenu = NSMenu(title: AppConstants.Bundle.displayName)
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(AppDelegate.openPreferences), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(AppConstants.Bundle.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Window", action: #selector(AppDelegate.openNewWindow), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "Split Vertically", action: #selector(AppDelegate.splitVertically), keyEquivalent: "d"))
        let horizontal = NSMenuItem(title: "Split Horizontally", action: #selector(AppDelegate.splitHorizontally), keyEquivalent: "D")
        horizontal.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(horizontal)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cut.target = nil
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.target = nil
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.target = nil
        editMenu.addItem(cut)
        editMenu.addItem(copy)
        editMenu.addItem(paste)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        for item in mainMenu.items {
            item.target = target
            guard item.submenu !== editMenu else { continue }
            item.submenu?.items.forEach { $0.target = target }
        }

        NSApp.mainMenu = mainMenu
    }
}
