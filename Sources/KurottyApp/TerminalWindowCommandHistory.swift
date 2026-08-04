import AppKit

/// Command-history panel integration for the terminal window: a collapsible
/// left split pane hosting `TerminalCommandHistoryPanelView` next to the
/// existing tab chrome. Extracted from `TerminalWindowController` to keep the
/// controller focused on tab/window behavior.
extension TerminalWindowController {
    func configureCommandHistorySplit(in rootView: NSView) {
        commandHistorySplitView.isVertical = true
        commandHistorySplitView.dividerStyle = .thin
        commandHistorySplitView.autosaveName = AppConstants.CommandHistory.splitViewAutosaveName
        commandHistorySplitView.translatesAutoresizingMaskIntoConstraints = false

        commandHistoryPanel.wantsLayer = true
        commandHistoryPanel.layer?.cornerRadius = 0
        commandHistoryPanel.layer?.borderWidth = 0
        commandHistoryPanel.layer?.masksToBounds = false
        commandHistoryPanel.translatesAutoresizingMaskIntoConstraints = false
        terminalContentHostView.translatesAutoresizingMaskIntoConstraints = false
        commandHistorySplitView.addArrangedSubview(commandHistoryPanel)
        commandHistorySplitView.addArrangedSubview(terminalContentHostView)
        commandHistorySplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        commandHistorySplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let preferredWidthConstraint = commandHistoryPanel.widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.commandHistoryPanelDefaultWidthPX
        )
        preferredWidthConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([
            commandHistoryPanel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.commandHistoryPanelMinWidthPX
            ),
            commandHistoryPanel.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.commandHistoryPanelMaxWidthPX
            ),
            preferredWidthConstraint,
        ])

        commandHistorySplitView.delegate = self
        rootView.addSubview(commandHistorySplitView)
        NSLayoutConstraint.activate([
            commandHistorySplitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandHistorySplitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            // The window-wide chrome bar owns the top strip, so panels start
            // below it and never collide with the title bar's traffic lights.
            commandHistorySplitView.topAnchor.constraint(equalTo: chromeBarBottomAnchor),
            commandHistorySplitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        // The panel starts collapsed; a hidden NSSplitView arranged subview is
        // the standard collapse mechanism and keeps the divider inactive.
        commandHistoryPanel.isHidden = true
        configureCommandHistoryPanelHandlers()
    }

    var isCommandHistoryPanelVisible: Bool {
        !commandHistoryPanel.isHidden
    }

    func toggleCommandHistoryPanel() {
        setCommandHistoryPanelVisible(!isCommandHistoryPanelVisible)
    }

    func setCommandHistoryPanelVisible(_ visible: Bool) {
        guard isCommandHistoryPanelVisible != visible else {
            return
        }
        commandHistoryPanel.isHidden = !visible
        commandHistorySplitView.adjustSubviews()
        updateSidebarToggleButtonStates()
        if visible {
            restoreSidebarWidthIfCollapsed(commandHistoryPanel)
            commandHistoryPanel.focusFilterField()
        } else {
            currentSplitView()?.focusFirstPane()
        }
    }

    private func configureCommandHistoryPanelHandlers() {
        commandHistoryPanel.onInsertCommand = { [weak self] entry in
            self?.insertHistoryCommandIntoActiveTerminal(entry)
        }
        commandHistoryPanel.onRunCommand = { [weak self] entry in
            self?.runHistoryCommandAfterExplicitApproval(entry)
        }
    }

    /// Safe default: put the command text on the active prompt without a
    /// trailing newline so it is never executed without the user pressing
    /// Return themselves.
    func insertHistoryCommandIntoActiveTerminal(_ entry: TerminalCommandHistoryEntry) {
        sendTextToActivePane(entry.commandText)
        currentSplitView()?.focusFirstPane()
    }

    /// Running a stored command always routes through the existing replay
    /// dispatcher gate: without `TerminalCommandReplayApproval` carrying an
    /// explicit confirmation, the dispatcher refuses and nothing is sent.
    func runHistoryCommandAfterExplicitApproval(_ entry: TerminalCommandHistoryEntry) {
        guard let candidate = TerminalCommandHistoryReplay.replayCandidate(for: entry),
              let replayCommand = TerminalCommandDispatcher.commandSpanCommand(for: .replay, registry: .localized)
        else {
            return
        }
        let approval = TerminalCommandReplayApproval(
            isExplicitlyConfirmed: confirmHistoryCommandReplay(candidate)
        )
        var approvedCommandText: String?
        let result = TerminalCommandDispatcher.execute(
            replayCommand,
            context: .replay(candidate, approval: approval),
            handlers: TerminalCommandSpanDispatchHandlers(
                replay: { candidate, _ in
                    approvedCommandText = candidate.commandText
                }
            )
        )
        guard result == .dispatched, let approvedCommandText else {
            return
        }
        sendTextToActivePane(approvedCommandText + "\n")
        currentSplitView()?.focusFirstPane()
    }

    private func confirmHistoryCommandReplay(_ candidate: TerminalCommandReplayCandidate) -> Bool {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.replayCommandQuestion)
        alert.informativeText = candidate.commandText
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.replay))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
