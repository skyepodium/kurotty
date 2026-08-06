import AppKit

/// Center settings tab.
///
/// Settings used to open as a small window of its own, which made it the one
/// surface that was not part of the app: a fixed 720pt page floating over the
/// terminal. It is now one more non-terminal center tab beside editor and
/// transcript tabs, so it needs no hosting mechanism of its own and inherits
/// their containment contract — the hosted view is not a `SplitTerminalView`,
/// so every terminal-only controller path falls through it as a no-op.
extension TerminalWindowController {
    /// Opens settings in a center tab, reusing the tab that already shows it.
    /// One settings surface per window: two would be two editors of the same
    /// file on disk, racing each other's autosave.
    @discardableResult
    func openSettingsTab() -> NSTabViewItem {
        if let existing = settingsTabItem {
            tabView.selectTabViewItem(existing)
            window?.title = existing.label
            updateTabBar()
            return existing
        }

        let settings = PreferencesView(frame: tabView.bounds)
        let item = NSTabViewItem(identifier: UUID().uuidString)
        item.view = settings
        item.label = settingsTabLabel
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        window?.title = item.label
        updateTabBar()
        return item
    }

    func settingsView(in item: NSTabViewItem) -> PreferencesView? {
        item.view as? PreferencesView
    }

    var settingsTabItem: NSTabViewItem? {
        (0..<tabView.numberOfTabViewItems)
            .map { tabView.tabViewItem(at: $0) }
            .first { settingsView(in: $0) != nil }
    }

    var hasOpenSettingsTab: Bool { settingsTabItem != nil }

    /// Retranslates an open settings tab after a language switch: the tab label
    /// belongs to the window, the page's own copy belongs to the view.
    func refreshSettingsTabLocalization() {
        guard let item = settingsTabItem else { return }
        item.label = settingsTabLabel
        if item === tabView.selectedTabViewItem {
            window?.title = item.label
        }
        settingsView(in: item)?.refreshLocalization()
        updateTabBar()
    }

    private var settingsTabLabel: String {
        PreferencesCopy.string(.settingsTitle, language: AppLocalization.language)
    }
}
