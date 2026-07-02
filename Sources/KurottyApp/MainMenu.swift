import AppKit

enum MainMenu {
    @MainActor
    static func install(target: AppDelegate) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = AppConstants.Bundle.displayName
        let appMenu = NSMenu(title: AppConstants.Bundle.displayName)
        appMenu.addItem(NSMenuItem(title: "About \(AppConstants.Bundle.displayName)", action: #selector(AppDelegate.showAboutPanel), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let checkForUpdates = NSMenuItem(title: "Check for Updates...", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = target
        appMenu.addItem(checkForUpdates)
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(AppDelegate.openPreferences), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(AppConstants.Bundle.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Window", action: #selector(AppDelegate.openNewWindow), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "Close Pane or Tab", action: #selector(AppDelegate.closeCurrentPane), keyEquivalent: "w"))
        let closePane = NSMenuItem(title: "Close Pane", action: #selector(AppDelegate.closeCurrentPane), keyEquivalent: "w")
        closePane.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closePane)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Split Vertically", action: #selector(AppDelegate.splitVertically), keyEquivalent: "d"))
        let horizontal = NSMenuItem(title: "Split Horizontally", action: #selector(AppDelegate.splitHorizontally), keyEquivalent: "D")
        horizontal.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(horizontal)
        fileMenu.addItem(.separator())
        let previousTab = NSMenuItem(title: "Previous Tab", action: #selector(AppDelegate.selectPreviousTab), keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(previousTab)
        let nextTab = NSMenuItem(title: "Next Tab", action: #selector(AppDelegate.selectNextTab), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(nextTab)
        fileMenu.addItem(.separator())
        let commandPalette = NSMenuItem(title: "Command Palette...", action: #selector(AppDelegate.openCommandPalette), keyEquivalent: "P")
        commandPalette.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(commandPalette)
        let saveWorkspace = NSMenuItem(title: "Save Workspace Snapshot", action: #selector(AppDelegate.saveWorkspaceSnapshot), keyEquivalent: "s")
        saveWorkspace.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(saveWorkspace)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let tmuxMenuItem = NSMenuItem()
        let tmuxMenu = NSMenu(title: AppConstants.Tmux.menuTitle)
        let attachTmux = NSMenuItem(title: AppConstants.Tmux.attachOrCreateSessionMenuTitle, action: #selector(AppDelegate.tmuxAttachOrCreateSession), keyEquivalent: "t")
        attachTmux.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(attachTmux)
        let listTmux = NSMenuItem(title: AppConstants.Tmux.listSessionsMenuTitle, action: #selector(AppDelegate.tmuxListSessions), keyEquivalent: "l")
        listTmux.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(listTmux)
        let applyTmuxTheme = NSMenuItem(title: AppConstants.Tmux.applyKurottyThemeMenuTitle, action: #selector(AppDelegate.tmuxApplyKurottyTheme), keyEquivalent: "p")
        applyTmuxTheme.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(applyTmuxTheme)
        tmuxMenu.addItem(.separator())
        let newTmuxWindow = NSMenuItem(title: AppConstants.Tmux.newWindowMenuTitle, action: #selector(AppDelegate.tmuxNewWindow), keyEquivalent: "n")
        newTmuxWindow.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(newTmuxWindow)
        let horizontalTmuxSplit = NSMenuItem(title: AppConstants.Tmux.splitHorizontallyMenuTitle, action: #selector(AppDelegate.tmuxSplitHorizontally), keyEquivalent: "d")
        horizontalTmuxSplit.keyEquivalentModifierMask = [.command, .option, .shift]
        tmuxMenu.addItem(horizontalTmuxSplit)
        let verticalTmuxSplit = NSMenuItem(title: AppConstants.Tmux.splitVerticallyMenuTitle, action: #selector(AppDelegate.tmuxSplitVertically), keyEquivalent: "d")
        verticalTmuxSplit.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(verticalTmuxSplit)
        tmuxMenu.addItem(.separator())
        let previousTmuxWindow = NSMenuItem(title: AppConstants.Tmux.previousWindowMenuTitle, action: #selector(AppDelegate.tmuxPreviousWindow), keyEquivalent: "[")
        previousTmuxWindow.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(previousTmuxWindow)
        let nextTmuxWindow = NSMenuItem(title: AppConstants.Tmux.nextWindowMenuTitle, action: #selector(AppDelegate.tmuxNextWindow), keyEquivalent: "]")
        nextTmuxWindow.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(nextTmuxWindow)
        tmuxMenu.addItem(.separator())
        let detachTmux = NSMenuItem(title: AppConstants.Tmux.detachClientMenuTitle, action: #selector(AppDelegate.tmuxDetachClient), keyEquivalent: "w")
        detachTmux.keyEquivalentModifierMask = [.command, .option]
        tmuxMenu.addItem(detachTmux)
        tmuxMenuItem.submenu = tmuxMenu
        mainMenu.addItem(tmuxMenuItem)

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
