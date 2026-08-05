import AppKit

enum MainMenu {
    // The Edit menu is hidden, so this title is never user-visible today.
    // Migrate to an AppLocalization `.selectAll` key if the menu is ever shown.
    private static let selectAllMenuTitle = "Select All"

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
        fileMenu.addItem(NSMenuItem(
            title: AppLocalization.string(.findTerminalOutput),
            action: #selector(AppDelegate.findTerminalOutput),
            keyEquivalent: "f"
        ))
        let commandPalette = NSMenuItem(title: AppLocalization.string(.commandPalette) + "...", action: #selector(AppDelegate.openCommandPalette), keyEquivalent: "P")
        commandPalette.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(commandPalette)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: AppLocalization.string(.view))
        let commandHistory = NSMenuItem(
            title: AppLocalization.string(.commandHistory),
            action: #selector(AppDelegate.toggleCommandHistoryPanel),
            keyEquivalent: "y"
        )
        commandHistory.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(commandHistory)
        let agentSessions = NSMenuItem(
            title: AppLocalization.string(.agentSessions),
            action: #selector(AppDelegate.toggleAgentSessionPanel),
            keyEquivalent: "A"
        )
        agentSessions.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(agentSessions)
        let fileExplorer = NSMenuItem(
            title: AppLocalization.string(.fileExplorer),
            action: #selector(AppDelegate.toggleFileExplorerPanel),
            keyEquivalent: "e"
        )
        fileExplorer.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(fileExplorer)
        // ⌘⇧K: free in TerminalCommandRegistry, in this menu, and in the
        // surface's key handling. Targets the feature's own action object so
        // quick commands do not add a case to AppDelegate.
        let quickCommands = NSMenuItem(
            title: AppLocalization.string(.quickCommands) + "…",
            action: #selector(QuickCommandsMenuActionTarget.showQuickCommandsEditor(_:)),
            keyEquivalent: "K"
        )
        quickCommands.keyEquivalentModifierMask = [.command, .shift]
        quickCommands.target = QuickCommandsMenuActionTarget.shared
        viewMenu.addItem(quickCommands)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Help owns the one-shot diagnostics report. It targets the feature's
        // own action object so the report does not add a case to AppDelegate.
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: AppLocalization.string(.help))
        let copyDiagnosticsReport = NSMenuItem(
            title: AppLocalization.string(.copyDiagnosticsReport),
            action: #selector(DiagnosticsReportMenuActionTarget.copyDiagnosticsReport(_:)),
            keyEquivalent: ""
        )
        copyDiagnosticsReport.target = DiagnosticsReportMenuActionTarget.shared
        helpMenu.addItem(copyDiagnosticsReport)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

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
        // Select All resolves through the responder chain so the focused
        // terminal surface receives it. The keyEquivalent match alone is not
        // enough under non-Latin input sources (2-set Korean reports "ㅁ" for
        // the A key), so TerminalSurfaceView also matches Cmd+A by hardware
        // keyCode in its own command-key handling.
        let selectAll = NSMenuItem(title: selectAllMenuTitle, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.target = nil
        editMenu.addItem(cut)
        editMenu.addItem(copy)
        editMenu.addItem(paste)
        editMenu.addItem(selectAll)
        editMenuItem.submenu = editMenu
        editMenuItem.isHidden = true
        mainMenu.addItem(editMenuItem)

        for item in mainMenu.items {
            item.target = target
            // The Edit menu resolves through the responder chain, and the Help
            // menu keeps the diagnostics report's own action object, so neither
            // may have its item targets rewritten to the app delegate.
            guard item.submenu !== editMenu, item.submenu !== helpMenu else { continue }
            // Items that already carry their own action object keep it: the
            // app delegate does not implement their selectors, so rewriting
            // the target here would leave them permanently disabled.
            item.submenu?.items.forEach { submenuItem in
                guard submenuItem.target == nil else { return }
                submenuItem.target = target
            }
        }

        NSApp.mainMenu = mainMenu
    }
}
