import AppKit

/// Close confirmation for tabs and windows whose shells still run a process.
///
/// Extracted from `TerminalWindowController` the same way the status bar and
/// command-history splits are: the controller stays tab/window wiring while
/// this file owns the guard. Two call paths exist and they never overlap:
/// closing one tab among several confirms just that tab's panes, while closing
/// the window (last tab's Cmd+W funnels into `performClose`, the red traffic
/// light, Cmd+Shift+W) confirms every pane through `windowShouldClose`.
///
/// The setting is live-applied: the flag is read from the current settings at
/// the moment of each close, so turning it off in Preferences takes effect on
/// the very next close with no restart.
extension TerminalWindowController {
    /// True when the close may proceed. Prompts only when the setting is on
    /// and at least one shell in `shellProcessIdentifiers` has a running child.
    func confirmCloseIfRunningProcess(shellProcessIdentifiers: [pid_t]) -> Bool {
        guard isCloseConfirmationEnabled else { return true }
        let names = TerminalCloseConfirmation.runningProcessNames(
            shellProcessIdentifiers: shellProcessIdentifiers
        )
        guard !names.isEmpty else { return true }
        return presentCloseConfirmation(processNames: names)
    }

    /// One tab's shell pids; tmux placeholders and sessions without a real
    /// child report `nil` and are skipped before any process call.
    func shellProcessIdentifiers(in item: NSTabViewItem) -> [pid_t] {
        guard let splitView = item.view as? SplitTerminalView else { return [] }
        return splitView.statusBarPaneDescriptors().compactMap(\.shellProcessIdentifier)
    }

    /// Every tab's shell pids, for window-level close.
    var allTabShellProcessIdentifiers: [pid_t] {
        tabView.tabViewItems
            .compactMap { $0.view as? SplitTerminalView }
            .flatMap { $0.statusBarPaneDescriptors().compactMap(\.shellProcessIdentifier) }
    }

    private var isCloseConfirmationEnabled: Bool {
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        return settings.terminal.confirmCloseRunningProcess
    }

    private func presentCloseConfirmation(processNames: [String]) -> Bool {
        if let resolved = TerminalCloseConfirmation.resolvedWithoutPresenting(processNames: processNames) {
            return resolved
        }
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.closeRunningProcessTitle)
        alert.informativeText = AppLocalization.format(
            .closeRunningProcessMessage,
            TerminalCloseConfirmation.displayedProcessList(processNames)
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppLocalization.string(.closeRunningProcessConfirm))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmCloseIfRunningProcess(shellProcessIdentifiers: allTabShellProcessIdentifiers)
    }
}
