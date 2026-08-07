import AppKit

/// Getting Started center tab.
///
/// Hosted the same way settings, editors, and transcripts are: an
/// `NSTabViewItem` whose view is not a `SplitTerminalView`, so every
/// terminal-only controller path falls through it as a no-op. That containment
/// contract is written down in `TerminalWindowEditorTabs.swift`, and this tab
/// inherits it rather than inventing a hosting mechanism.
extension TerminalWindowController {
    /// Opens Getting Started, reusing the tab if it is already open. One per
    /// window, for the same reason settings is one per window: two copies of a
    /// page that reports the same machine is two copies of the same page.
    @discardableResult
    func openGettingStartedTab() -> NSTabViewItem {
        if let existing = gettingStartedTabItem {
            tabView.selectTabViewItem(existing)
            window?.title = existing.label
            refreshGettingStartedEnvironment()
            updateTabBar()
            return existing
        }

        let page = TerminalGettingStartedView(frame: tabView.bounds)
        page.applyChromeTheme(chromeTheme)
        page.onOpenSettings = { [weak self] in
            self?.openSettingsTab()
        }
        let item = NSTabViewItem(identifier: UUID().uuidString)
        item.view = page
        item.label = gettingStartedTabLabel
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        window?.title = item.label
        updateTabBar()
        refreshGettingStartedEnvironment()
        return item
    }

    /// Opens the tab exactly once, on the first launch of a fresh install.
    ///
    /// The flag is written before the tab is built rather than after: if
    /// anything below fails or the window goes away, the honest outcome is
    /// "the user has had their one chance at this". Repeatedly opening a
    /// welcome tab is a far worse failure than never opening it.
    ///
    /// Settings are read through the store rather than through a cached copy,
    /// matching `AgentStatusHookConsentStore` — this is the same kind of key,
    /// a record of something that happened rather than a preference, and it is
    /// touched once per launch.
    func openGettingStartedTabOnFirstRunIfNeeded() {
        guard var settings = try? AppSettingsStore.shared.load(),
              !settings.terminal.hasSeenGettingStarted
        else {
            return
        }
        settings.terminal.hasSeenGettingStarted = true
        try? AppSettingsStore.shared.save(settings)
        openGettingStartedTab()
    }

    func gettingStartedView(in item: NSTabViewItem) -> TerminalGettingStartedView? {
        item.view as? TerminalGettingStartedView
    }

    var gettingStartedTabItem: NSTabViewItem? {
        (0..<tabView.numberOfTabViewItems)
            .map { tabView.tabViewItem(at: $0) }
            .first { gettingStartedView(in: $0) != nil }
    }

    /// Re-runs the checks and repaints. Collection happens off the main actor
    /// because one of the checks spawns `rg --version`, and the page must not
    /// hold the main thread waiting on a process.
    func refreshGettingStartedEnvironment() {
        guard let item = gettingStartedTabItem,
              let page = gettingStartedView(in: item)
        else {
            return
        }
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        let shellConfiguration = TerminalShellIntegrationBootstrap.bundledConfiguration(
            shellPath: TerminalShellIntegrationBootstrap.loginShellPath()
        )
        let isInstalled = AppInstallLocation.verdictForRunningBundle() == .installed

        Task.detached(priority: .utility) {
            let isRipgrepAvailable = ProjectFileEnumerationRunner.isRipgrepAvailable()
            await MainActor.run {
                page.update(environment: TerminalSetupEnvironment(
                    shellInjectsCommandBoundaries: shellConfiguration.automaticallyInjectsCommandBoundaries,
                    agentStatusHooksEnabled: settings.terminal.agentStatusHooksEnabled,
                    agentStatusHookConsents: AgentStatusHookTarget.allCases.map {
                        settings.terminal.agentStatusHookConsentChoice(for: $0)
                    },
                    agentSessionIndexEnabled: settings.terminal.agentSessionIndexEnabled,
                    isRipgrepAvailable: isRipgrepAvailable,
                    isInstalledInApplications: isInstalled
                ))
            }
        }
    }

    /// Retranslates an open tab after a language switch, matching the settings
    /// tab: the label belongs to the window, the page's copy to the view.
    func refreshGettingStartedTabLocalization() {
        guard let item = gettingStartedTabItem else {
            return
        }
        item.label = gettingStartedTabLabel
        if item === tabView.selectedTabViewItem {
            window?.title = item.label
        }
        gettingStartedView(in: item)?.refreshLocalization()
        updateTabBar()
    }

    private var gettingStartedTabLabel: String {
        AppLocalization.string(.gettingStarted, language: AppLocalization.language)
    }
}
