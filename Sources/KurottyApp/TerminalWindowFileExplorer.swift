import AppKit

/// Shared single-quote shell quoting so paths inserted into the terminal
/// survive spaces and metacharacters. Used by the file-explorer insert-path
/// action and the command-history `cd` copy action.
enum TerminalShellPathQuoting {
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// File-explorer panel integration for the terminal window: a collapsible
/// right split pane hosting `TerminalFileExplorerPanelView` that always shows
/// the active pane's OSC 7 working directory. Extracted from
/// `TerminalWindowController` to keep the controller focused on tab/window
/// behavior; the sibling left-panel integration lives in
/// TerminalWindowCommandHistory.swift.
extension TerminalWindowController {
    func configureFileExplorerPane() {
        fileExplorerPanel.translatesAutoresizingMaskIntoConstraints = false
        fileExplorerPanel.wantsLayer = true
        fileExplorerPanel.layer?.cornerRadius = 0
        fileExplorerPanel.layer?.borderWidth = 0
        fileExplorerPanel.layer?.masksToBounds = false
        commandHistorySplitView.addArrangedSubview(fileExplorerPanel)
        let explorerSubviewIndex = commandHistorySplitView.arrangedSubviews.count - 1
        commandHistorySplitView.setHoldingPriority(.defaultHigh, forSubviewAt: explorerSubviewIndex)

        let preferredWidthConstraint = fileExplorerPanel.widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.fileExplorerPanelDefaultWidthPX
        )
        preferredWidthConstraint.priority = .defaultLow
        // Held inactive while the panel is hidden; see
        // `setSidebarPanelHidden(_:panel:widthConstraints:)` for why.
        fileExplorerWidthConstraints = [
            fileExplorerPanel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.fileExplorerPanelMinWidthPX
            ),
            fileExplorerPanel.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.fileExplorerPanelMaxWidthPX
            ),
            preferredWidthConstraint,
        ]

        // The panel starts collapsed through the shared helper so the hidden
        // state, the released width constraints, and the zero-width pin are
        // established exactly once, in one place.
        setSidebarPanelHidden(
            true,
            panel: fileExplorerPanel,
            widthConstraints: fileExplorerWidthConstraints
        )
        fileExplorerPanel.callbacks = TerminalFileExplorerCallbacks(
            openFile: { [weak self] url in
                self?.openEditorTab(for: url)
            },
            insertPath: { [weak self] path in
                self?.insertFileExplorerPathIntoActiveTerminal(path)
            }
        )
        observePaneFocusForFileExplorer()
    }

    var isFileExplorerPanelVisible: Bool {
        !fileExplorerPanel.isHidden
    }

    func toggleFileExplorerPanel() {
        setFileExplorerPanelVisible(!isFileExplorerPanelVisible)
    }

    func setFileExplorerPanelVisible(_ visible: Bool) {
        guard isFileExplorerPanelVisible != visible else {
            return
        }
        setSidebarPanelHidden(
            !visible,
            panel: fileExplorerPanel,
            widthConstraints: fileExplorerWidthConstraints
        )
        updateSidebarToggleButtonStates()
        if visible {
            restoreSidebarWidthIfCollapsed(fileExplorerPanel)
            refreshFileExplorerRootDirectory()
            fileExplorerPanel.focusSearchField()
        } else {
            currentSplitView()?.focusFirstPane()
        }
    }

    /// Re-points the panel at the active pane's working *location*, local or
    /// remote. Safe to call redundantly: both `update(location:)` paths are
    /// idempotent for an unchanged location. When an editor tab is selected the
    /// previous root is kept so the tree does not jump while browsing a file.
    ///
    /// The location — not a bare URL — is what reaches the panel, so an SSH
    /// session lands in the remote empty state instead of listing a same-named
    /// local path.
    func refreshFileExplorerRootDirectory() {
        guard isFileExplorerPanelVisible else {
            return
        }
        guard let splitView = currentSplitView() else {
            return
        }
        guard let surface = splitView.activeTerminalSurface() else {
            fileExplorerPanel.update(rootDirectory: FileManager.default.homeDirectoryForCurrentUser)
            return
        }
        fileExplorerPanel.update(location: surface.workingDirectoryLocation)
    }

    /// Safe default mirroring the command-history insert: put the quoted path
    /// on the active prompt without a trailing newline so nothing executes
    /// without the user pressing Return themselves.
    func insertFileExplorerPathIntoActiveTerminal(_ path: String) {
        sendTextToActivePane(TerminalShellPathQuoting.quoted(path))
        currentSplitView()?.focusFirstPane()
    }

    private func observePaneFocusForFileExplorer() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneFocusDidChangeForFileExplorer(_:)),
            name: TerminalSurfaceView.focusDidChangeNotification,
            object: nil
        )
    }

    @objc private func paneFocusDidChangeForFileExplorer(_ notification: Notification) {
        refreshFileExplorerRootDirectory()
    }
}
