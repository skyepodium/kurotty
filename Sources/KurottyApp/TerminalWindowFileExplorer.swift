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
        fileExplorerPanel.layer?.cornerRadius = DesignTokens.Component.fileExplorerPanelCornerRadiusPX
        fileExplorerPanel.layer?.borderWidth = DesignTokens.Component.hairlinePX
        fileExplorerPanel.layer?.borderColor = chromeTheme.borderHairline.cgColor
        fileExplorerPanel.layer?.masksToBounds = true
        commandHistorySplitView.addArrangedSubview(fileExplorerPanel)
        let explorerSubviewIndex = commandHistorySplitView.arrangedSubviews.count - 1
        commandHistorySplitView.setHoldingPriority(.defaultHigh, forSubviewAt: explorerSubviewIndex)

        let preferredWidthConstraint = fileExplorerPanel.widthAnchor.constraint(
            equalToConstant: DesignTokens.Component.fileExplorerPanelDefaultWidthPX
        )
        preferredWidthConstraint.priority = .defaultLow
        NSLayoutConstraint.activate([
            fileExplorerPanel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: DesignTokens.Component.fileExplorerPanelMinWidthPX
            ),
            fileExplorerPanel.widthAnchor.constraint(
                lessThanOrEqualToConstant: DesignTokens.Component.fileExplorerPanelMaxWidthPX
            ),
            preferredWidthConstraint,
        ])

        // The panel starts collapsed; a hidden NSSplitView arranged subview is
        // the standard collapse mechanism and keeps the divider inactive.
        fileExplorerPanel.isHidden = true
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
        fileExplorerPanel.isHidden = !visible
        commandHistorySplitView.adjustSubviews()
        updateSidebarToggleButtonStates()
        if visible {
            restoreSidebarWidthIfCollapsed(fileExplorerPanel)
            refreshFileExplorerRootDirectory()
            fileExplorerPanel.focusSearchField()
        } else {
            currentSplitView()?.focusFirstPane()
        }
    }

    /// Re-points the panel at the active pane's working directory. Safe to
    /// call redundantly: `update(rootDirectory:)` is idempotent for an
    /// unchanged directory. When an editor tab is selected the previous root
    /// is kept so the tree does not jump while browsing a file.
    func refreshFileExplorerRootDirectory() {
        guard isFileExplorerPanelVisible else {
            return
        }
        guard let splitView = currentSplitView() else {
            return
        }
        fileExplorerPanel.update(rootDirectory: workingDirectoryURL(for: splitView))
    }

    private func workingDirectoryURL(for splitView: SplitTerminalView) -> URL {
        guard let surface = splitView.activeTerminalSurface() else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        let path = surface.workingDirectoryPath
        guard !path.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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
