import AppKit

/// Left sidebar integration for the terminal window: a collapsible left split
/// pane hosting `TerminalLeftSidebarPanelView`, which switches between the
/// command-history and agent-session sections, next to the existing tab chrome.
/// Extracted from `TerminalWindowController` to keep the controller focused on
/// tab/window behavior.
extension TerminalWindowController {
    func configureCommandHistorySplit(in rootView: NSView) {
        commandHistorySplitView.isVertical = true
        commandHistorySplitView.dividerStyle = .thin
        commandHistorySplitView.autosaveName = AppConstants.CommandHistory.splitViewAutosaveName
        commandHistorySplitView.translatesAutoresizingMaskIntoConstraints = false

        leftSidebarPanel.wantsLayer = true
        leftSidebarPanel.layer?.cornerRadius = 0
        leftSidebarPanel.layer?.borderWidth = 0
        leftSidebarPanel.layer?.masksToBounds = false
        leftSidebarPanel.translatesAutoresizingMaskIntoConstraints = false
        terminalContentHostView.translatesAutoresizingMaskIntoConstraints = false
        commandHistorySplitView.addArrangedSubview(leftSidebarPanel)
        commandHistorySplitView.addArrangedSubview(terminalContentHostView)
        commandHistorySplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        commandHistorySplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let preferredWidthConstraint = leftSidebarPanel.widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.commandHistoryPanelDefaultWidthPX
        )
        preferredWidthConstraint.priority = .defaultLow
        // Held inactive while the panel is hidden; see
        // `commandHistoryWidthConstraints` for why.
        commandHistoryWidthConstraints = [
            leftSidebarPanel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.commandHistoryPanelMinWidthPX
            ),
            leftSidebarPanel.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.commandHistoryPanelMaxWidthPX
            ),
            preferredWidthConstraint,
        ]

        commandHistorySplitView.delegate = self
        rootView.addSubview(commandHistorySplitView)
        NSLayoutConstraint.activate([
            commandHistorySplitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            commandHistorySplitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            // The window-wide chrome bar owns the top strip, so panels start
            // below it and never collide with the title bar's traffic lights.
            commandHistorySplitView.topAnchor.constraint(equalTo: chromeBarBottomAnchor),
            // The bottom status bar owns the bottom strip the same way the
            // chrome bar owns the top one, so the split stops at its top edge
            // instead of running under it.
            commandHistorySplitView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
        ])

        // The panel starts collapsed through the shared helper so the hidden
        // state, the released width constraints, and the zero-width pin are
        // established exactly once, in one place.
        setSidebarPanelHidden(
            true,
            panel: leftSidebarPanel,
            widthConstraints: commandHistoryWidthConstraints
        )
        configureCommandHistoryPanelHandlers()
    }

    var isCommandHistoryPanelVisible: Bool {
        !leftSidebarPanel.isHidden
    }

    var selectedLeftSidebarSection: TerminalLeftSidebarSection {
        leftSidebarPanel.selectedSection
    }

    func toggleCommandHistoryPanel() {
        setCommandHistoryPanelVisible(!isCommandHistoryPanelVisible)
    }

    func setCommandHistoryPanelVisible(_ visible: Bool) {
        guard isCommandHistoryPanelVisible != visible else {
            return
        }
        setSidebarPanelHidden(
            !visible,
            panel: leftSidebarPanel,
            widthConstraints: commandHistoryWidthConstraints
        )
        updateSidebarToggleButtonStates()
        if visible {
            restoreSidebarWidthIfCollapsed(leftSidebarPanel)
            leftSidebarPanel.focusFilterField()
        } else {
            currentSplitView()?.focusFirstPane()
        }
    }

    /// Shows the left panel with a specific section selected. Used by the View
    /// menu, the command palette, and the debug launch flags.
    func setCommandHistoryPanelVisible(_ visible: Bool, section: TerminalLeftSidebarSection) {
        if visible {
            leftSidebarPanel.showSection(section)
        }
        guard isCommandHistoryPanelVisible != visible else {
            if visible {
                leftSidebarPanel.focusFilterField()
            }
            return
        }
        setCommandHistoryPanelVisible(visible)
    }

    /// Toggle used by the agent-session command: closes the panel only when it
    /// is already showing that section, otherwise switches to it.
    func toggleAgentSessionPanel() {
        guard isCommandHistoryPanelVisible, selectedLeftSidebarSection == .agentSessions else {
            setCommandHistoryPanelVisible(true, section: .agentSessions)
            return
        }
        setCommandHistoryPanelVisible(false)
    }

    private func configureCommandHistoryPanelHandlers() {
        commandHistoryPanel.onInsertCommand = { [weak self] entry in
            self?.insertHistoryCommandIntoActiveTerminal(entry)
        }
        commandHistoryPanel.onRunCommand = { [weak self] entry in
            self?.runHistoryCommandAfterExplicitApproval(entry)
        }
        agentSessionPanel.onInsertResumeCommand = { [weak self] record in
            self?.insertAgentSessionResumeCommandIntoActiveTerminal(record)
        }
        agentSessionPanel.onOpenDirectoryInExplorer = { [weak self] record in
            self?.openAgentSessionDirectoryInExplorer(record)
        }
        // Single-click opens the read-only viewer in a center tab; double-click
        // stays on the insert-resume-command path.
        agentSessionPanel.onOpenTranscript = { [weak self] record in
            self?.openTranscriptTab(for: record)
        }
    }

    /// Safe default, identical to the history panel's insert: put the resume
    /// command on the active prompt without a trailing newline. There is no
    /// execute path for agent sessions at all, so the user always presses
    /// Return themselves.
    func insertAgentSessionResumeCommandIntoActiveTerminal(_ record: AgentSessionRecord) {
        sendTextToActivePane(AgentSessionResumeCommand.command(for: record))
        currentSplitView()?.focusFirstPane()
    }

    func openAgentSessionDirectoryInExplorer(_ record: AgentSessionRecord) {
        let cwd = record.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else {
            return
        }
        setFileExplorerPanelVisible(true)
        fileExplorerPanel.update(rootDirectory: URL(fileURLWithPath: cwd, isDirectory: true))
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
            isExplicitlyConfirmed: confirmHistoryCommandReplay(entry)
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

    /// Replay always runs in the *local* pane, so a remote entry's dialog leads
    /// with its `user@host:` origin instead of showing a bare command line.
    private func confirmHistoryCommandReplay(_ entry: TerminalCommandHistoryEntry) -> Bool {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.replayCommandQuestion)
        alert.informativeText = TerminalCommandHistoryReplay.confirmationInformativeText(for: entry)
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: AppLocalization.string(.replay))
        alert.addButton(withTitle: AppLocalization.string(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
