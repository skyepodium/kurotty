import AppKit

/// Right-side file-explorer panel showing the current working directory as a
/// lazy tree with git badges, name filtering, and a coalesced root watcher.
///
/// Wiring contract: instantiate, assign `callbacks`, call
/// `update(rootDirectory:)` when the tracked directory changes, and forward
/// theme changes through `applyChromeTheme(_:)`.
///
/// The callback surface, outline item, and root watcher live in
/// `TerminalFileExplorerOutline.swift`.

// MARK: - Panel view

@MainActor
final class TerminalFileExplorerPanelView: NSView {
    var callbacks = TerminalFileExplorerCallbacks()

    private(set) var rootDirectory: URL?
    /// Set while the active pane's working directory lives on another machine.
    /// The explorer browses local files only, so in this state it lists
    /// nothing, watches nothing, and runs no `git`.
    private(set) var remoteLocation: TerminalWorkingDirectoryLocation?
    private var rootItem: TerminalFileExplorerOutlineItem?
    private var filterMatchItems: [TerminalFileExplorerOutlineItem]?
    private var gitOverlay = FileExplorerGitOverlay.empty
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var watcher: TerminalFileExplorerRootWatcher?
    private var projectIconSourceCache: [URL: FileExplorerProjectIconSource] = [:]
    private var resolvedProjectIconURLs: Set<URL> = []
    private var projectIconResolutionTask: Task<Void, Never>?
    private var filterGeneration = 0
    private let gitStatusService = TerminalGitStatusService()
    /// Read-only source of "which agent wrote this file, from which prompt".
    /// The explorer never scans transcripts itself; it renders whatever the
    /// shared index already holds and asks it to rescan only on an explicit
    /// user action or a root change.
    private let agentSessionIndexStore: AgentSessionIndexStore
    private var agentProvenance = AgentFileProvenanceIndex.empty
    /// Create, rename, and trash. Injected so a test can exercise the panel's
    /// delete path without moving a fixture into the real Trash.
    private let entryWriter: FileExplorerEntryWriter
    /// Prompts and writes; the panel reconciles the tree against the one
    /// outcome it hands back. Lazy because that outcome closure needs `self`.
    private lazy var entryActions = TerminalFileExplorerEntryActions(
        writer: entryWriter
    ) { [weak self] revealing, failure in
        self?.applyOutcome(revealing: revealing, failure: failure)
    }

    private let panelTitleLabel = NSTextField(labelWithString: "")
    private let glassBackgroundView = TerminalSidebarGlassBackgroundView(frame: .zero)
    private let directoryNameLabel = NSTextField(labelWithString: "")
    private let refreshButton = ChromeIconButton(
        symbolName: FileExplorerIcon.refreshSymbolName,
        accessibilityLabel: AppLocalization.string(.refresh),
        target: nil,
        action: nil
    )
    /// Shared sidebar control; see `TerminalSidebarSearchPillView`.
    private let searchPillView = TerminalSidebarSearchPillView(
        placeholder: { AppLocalization.string(.fileExplorerSearchPlaceholder) }
    )
    private let actionErrorRow = TerminalFileExplorerActionErrorRow(chromeTheme: .dark)
    private let listContainerView = NSView()
    private let scrollView = NSScrollView()
    private let outlineView = TerminalFileExplorerOutlineView()
    private let sidebarScroller = TerminalSidebarScroller(frame: .zero)
    private let emptyStateIconView = NSImageView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")

    init(
        agentSessionIndexStore: AgentSessionIndexStore = .shared,
        entryWriter: FileExplorerEntryWriter = .live
    ) {
        self.agentSessionIndexStore = agentSessionIndexStore
        self.entryWriter = entryWriter
        super.init(frame: .zero)
        configureSubviews()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentSessionIndexDidChange(_:)),
            name: AgentSessionIndexStore.didChangeNotification,
            object: agentSessionIndexStore
        )
        agentProvenance = agentSessionIndexStore.provenance
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API

    /// Primary entry point: points the panel at the active pane's working
    /// directory, local or remote. Remote sessions short-circuit before any
    /// filesystem, watcher, or `git` work.
    func update(location: TerminalWorkingDirectoryLocation) {
        guard location.isRemote else {
            update(rootDirectory: URL(fileURLWithPath: location.path, isDirectory: true))
            return
        }
        showRemoteLocation(location)
    }

    func update(rootDirectory: URL) {
        let standardized = rootDirectory.standardizedFileURL
        // A failure belongs to the directory it happened in; carrying it into
        // the next one would accuse a tree that never refused anything.
        if self.rootDirectory != standardized {
            actionErrorRow.present(nil)
        }
        if remoteLocation != nil {
            remoteLocation = nil
            self.rootDirectory = nil
            updateRemoteEmptyState()
        }
        if self.rootDirectory != standardized {
            self.rootDirectory = standardized
            invalidateProjectIconSources()
            directoryNameLabel.stringValue = standardized.lastPathComponent
            rootItem = TerminalFileExplorerOutlineItem(
                node: FileExplorerNode(url: standardized, kind: .directory)
            )
            watcher?.stop()
            watcher = TerminalFileExplorerRootWatcher(directoryURL: standardized) { [weak self] in
                self?.refresh()
            }
            gitOverlay = .empty
            outlineView.reloadData()
            // A new project is a new set of files to attribute, so the index is
            // asked to rescan here and on the explicit refresh action only.
            // Filesystem-watcher refreshes must not trigger a transcript walk.
            agentSessionIndexStore.refresh()
        }
        refresh()
    }

    /// Switches the panel into the remote empty state. Idempotent: repeating
    /// the same remote location does nothing, so a pane that keeps emitting
    /// OSC 7 for the same SSH directory cannot flicker the tree.
    private func showRemoteLocation(_ location: TerminalWorkingDirectoryLocation) {
        guard remoteLocation != location else {
            return
        }
        remoteLocation = location
        rootDirectory = nil
        rootItem = nil
        invalidateProjectIconSources()
        filterMatchItems = nil
        actionErrorRow.present(nil)
        // Invalidate any in-flight filter scan started for the previous local
        // root so its result cannot repopulate the tree after the switch.
        filterGeneration += 1
        gitOverlay = .empty
        watcher?.stop()
        watcher = nil
        outlineView.reloadData()
        updateRemoteEmptyState()
    }

    func refresh() {
        // A remote session has nothing local to list, watch, or `git` on.
        guard remoteLocation == nil else {
            return
        }
        guard let rootDirectory, let rootItem else {
            return
        }
        _ = rootItem.childItems()
        rootItem.refreshLoadedSubtree()
        resolveProjectIconsIfNeeded(in: rootItem.childItems(), rootDirectory: rootDirectory)
        outlineView.reloadData()
        reapplyFilterIfNeeded()
        gitStatusService.requestStatus(rootDirectory: rootDirectory) { [weak self] result in
            self?.applyGitStatus(result)
        }
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = NSColor.clear.cgColor
        glassBackgroundView.applyChromeTheme(theme)
        sidebarScroller.applyChromeTheme(theme)
        DesignTokens.Typography.rowTitleSel.apply(to: directoryNameLabel, color: theme.textPrimary)
        DesignTokens.Typography.sectionHeader.apply(to: panelTitleLabel, color: theme.textTertiary)
        searchPillView.applyChromeTheme(theme)
        outlineView.disclosureTintColor = theme.textTertiary
        refreshButton.applyChromeTheme(theme)
        actionErrorRow.applyChromeTheme(theme)
        applyEmptyStateIcon(tint: theme.textMuted)
        emptyStateLabel.textColor = theme.textMuted
        updateRemoteEmptyState()
        outlineView.reloadData()
    }

    func focusSearchField() {
        searchPillView.focus()
    }

    // MARK: Testing accessors

    var visibleRowCountForTesting: Int {
        outlineView.numberOfRows
    }

    var isRemoteEmptyStateHiddenForTesting: Bool {
        emptyStateLabel.isHidden && emptyStateIconView.isHidden
    }

    var remoteEmptyStateTextForTesting: String {
        emptyStateLabel.stringValue
    }

    var isSearchEnabledForTesting: Bool {
        searchPillView.isEnabled
    }

    /// Injects a provenance index without a store scan, so row markers and the
    /// transcript context action are testable against fixed touches.
    func setAgentProvenanceForTesting(_ index: AgentFileProvenanceIndex) {
        agentProvenance = index
        outlineView.reloadData()
    }

    func agentMarkerForTesting(absolutePath: String, now: Date) -> FileExplorerAgentMarker {
        FileExplorerAgentMarker.make(absolutePath: absolutePath, provenance: agentProvenance, now: now)
    }

    var contextMenuForTesting: NSMenu? {
        outlineView.menu
    }

    func selectRowForTesting(_ row: Int) {
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func rowNamesForTesting() -> [String] {
        (0..<outlineView.numberOfRows).compactMap {
            (outlineView.item(atRow: $0) as? TerminalFileExplorerOutlineItem)?.node.name
        }
    }

    var selectedRowNameForTesting: String? {
        let row = outlineView.selectedRow
        guard row >= 0 else {
            return nil
        }
        return (outlineView.item(atRow: row) as? TerminalFileExplorerOutlineItem)?.node.name
    }

    /// The inline failure sentence, or `nil` while the row is collapsed away.
    var actionErrorMessageForTesting: String? {
        actionErrorRow.message
    }

    var actionErrorRowHeightForTesting: CGFloat {
        actionErrorRow.frame.height
    }

    var listContainerHeightForTesting: CGFloat {
        listContainerView.frame.height
    }

    /// The create and rename paths minus their modal, which a test cannot
    /// answer. Everything after the typed name — validation, the write, the
    /// re-list, and the inline failure — is the code the menu items run.
    func createForTesting(_ action: FileExplorerEntryAction, named name: String) {
        guard let rootDirectory else {
            return
        }
        entryActions.create(
            action,
            named: name,
            in: FileExplorerCreationTarget.directory(
                forSelectedNode: clickedOrSelectedItem()?.node,
                rootDirectory: rootDirectory
            )
        )
    }

    func renameSelectionForTesting(to name: String) {
        guard let item = clickedOrSelectedItem() else {
            return
        }
        entryActions.rename(item.node.url, to: name)
    }

    func moveSelectionToTrashForTesting() {
        moveToTrashFromContextMenu(nil)
    }

    func entryActionIsAvailableForTesting(_ action: FileExplorerEntryAction) -> Bool {
        action.isAvailable(in: entryActionContext(for: clickedOrSelectedItem()))
    }

    // MARK: Setup

    private func configureSubviews() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor

        glassBackgroundView.applyChromeTheme(chromeTheme)
        glassBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassBackgroundView)
        NSLayoutConstraint.activate([
            glassBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            glassBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        panelTitleLabel.stringValue = AppLocalization.string(.fileExplorer).localizedUppercase
        DesignTokens.Typography.sectionHeader.apply(
            to: panelTitleLabel,
            color: chromeTheme.textTertiary
        )
        panelTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panelTitleLabel)

        DesignTokens.Typography.rowTitleSel.apply(
            to: directoryNameLabel,
            color: chromeTheme.textPrimary
        )
        directoryNameLabel.lineBreakMode = .byTruncatingMiddle
        directoryNameLabel.maximumNumberOfLines = 1
        directoryNameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(directoryNameLabel)

        refreshButton.applyChromeTheme(chromeTheme)
        refreshButton.toolTip = AppLocalization.string(.refresh)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)

        searchPillView.onQueryChanged = { [weak self] in
            self?.reapplyFilterIfNeeded()
        }
        searchPillView.applyChromeTheme(chromeTheme)
        searchPillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchPillView)

        actionErrorRow.applyChromeTheme(chromeTheme)
        actionErrorRow.present(nil)
        addSubview(actionErrorRow)

        listContainerView.wantsLayer = true
        listContainerView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        listContainerView.clipsToBounds = true
        listContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listContainerView)

        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.verticalScroller = sidebarScroller
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(scrollView)
        configureRemoteEmptyState()
        activateLayoutConstraints()
        updateRemoteEmptyState()
    }

    /// Palette-tinted symbols bake their color into the image, so a theme
    /// change has to rebuild these rather than reassign `contentTintColor`.
    private func applyEmptyStateIcon(tint: NSColor) {
        emptyStateIconView.image = Icon.symbol(
            FileExplorerIcon.remoteSymbolName,
            pointSizePT: DesignTokens.Component.commandHistoryEmptyStateIconPointSizePT,
            weight: .regular,
            tint: tint
        )
    }

    /// Empty state for remote sessions. Lives inside the list container, so it
    /// occupies the tree region only and can never overlap the header or the
    /// search pill.
    private func configureRemoteEmptyState() {
        applyEmptyStateIcon(tint: chromeTheme.textMuted)
        emptyStateIconView.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(emptyStateIconView)

        DesignTokens.Typography.rowTitle.apply(to: emptyStateLabel, color: chromeTheme.textMuted)
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(emptyStateLabel)
    }

    /// Shows or hides the remote message and keeps the local-only controls
    /// (search, refresh) disabled while there is nothing local to act on.
    private func updateRemoteEmptyState() {
        let isRemote = remoteLocation != nil
        emptyStateIconView.isHidden = !isRemote
        emptyStateLabel.isHidden = !isRemote
        scrollView.isHidden = isRemote
        searchPillView.isEnabled = !isRemote
        refreshButton.isEnabled = !isRemote
        emptyStateIconView.alphaValue = DesignTokens.Component.sidebarEmptyStateIconAlphaRATIO
        emptyStateLabel.alphaValue = DesignTokens.Component.sidebarEmptyStateLabelAlphaRATIO
        guard let remoteLocation else {
            emptyStateLabel.stringValue = ""
            return
        }
        searchPillView.stringValue = ""
        directoryNameLabel.stringValue = FileExplorerRemoteCopy.title()
        emptyStateLabel.stringValue = FileExplorerRemoteCopy.explanation(
            hostPath: TerminalCommandHistoryRowBuilder.hostPrefixed(
                remoteLocation.path,
                host: remoteLocation.remoteHost
            )
        )
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = DesignTokens.Component.fileExplorerOutlineIndentationPX
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.onRenameKey = { [weak self] in
            self?.renameFromContextMenu(nil)
        }
        outlineView.onTrashKey = { [weak self] in
            self?.moveToTrashFromContextMenu(nil)
        }
        outlineView.onFilterKey = { [weak self] in
            self?.focusSearchField()
        }
        outlineView.menu = makeContextMenu()
    }

    private func activateLayoutConstraints() {
        let insetX = DesignTokens.Component.fileExplorerPanelInsetXPX
        let insetY = DesignTokens.Component.fileExplorerPanelInsetYPX
        let controlGap = DesignTokens.Component.fileExplorerControlGapPX
        // No gap of its own: the row carries its own top padding and collapses
        // that padding with itself, so a panel with nothing to say lands the
        // list exactly where it did before the row existed.
        NSLayoutConstraint.activate([
            actionErrorRow.topAnchor.constraint(equalTo: searchPillView.bottomAnchor),
            actionErrorRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            actionErrorRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
        ])
        NSLayoutConstraint.activate([
            panelTitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: insetY),
            panelTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            panelTitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: refreshButton.leadingAnchor,
                constant: -controlGap
            ),

            refreshButton.centerYAnchor.constraint(equalTo: panelTitleLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            refreshButton.widthAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerRefreshButtonSizePX
            ),
            refreshButton.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerRefreshButtonSizePX
            ),

            directoryNameLabel.topAnchor.constraint(
                equalTo: panelTitleLabel.bottomAnchor,
                constant: DesignTokens.Component.fileExplorerHeaderGapPX
            ),
            directoryNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            directoryNameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -insetX
            ),

            searchPillView.topAnchor.constraint(
                equalTo: directoryNameLabel.bottomAnchor,
                constant: controlGap
            ),
            searchPillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            searchPillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),

            listContainerView.topAnchor.constraint(
                equalTo: actionErrorRow.bottomAnchor,
                constant: controlGap
            ),
            listContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: listContainerView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainerView.bottomAnchor),
        ] + TerminalSidebarEmptyStateLayout.constraints(
            iconView: emptyStateIconView,
            label: emptyStateLabel,
            in: listContainerView,
            insetX: insetX,
            insetY: insetY
        ))
    }

    // MARK: Git status

    private func applyGitStatus(_ result: TerminalGitStatusResult?) {
        guard let result else {
            gitOverlay = .empty
            outlineView.reloadData()
            return
        }
        gitOverlay = FileExplorerGitOverlay(
            repositoryRootPath: result.repositoryRootPath,
            snapshot: result.snapshot
        )
        outlineView.reloadData()
    }

    // MARK: Filtering

    private func reapplyFilterIfNeeded() {
        filterGeneration += 1
        // No local tree to scan while the session is remote.
        guard remoteLocation == nil else {
            filterMatchItems = nil
            return
        }
        let query = searchPillView.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            filterMatchItems = nil
            outlineView.reloadData()
            return
        }
        guard let rootDirectory else {
            return
        }
        let requestGeneration = filterGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let matches = FileExplorerFilterProjection.matches(
                rootDirectory: rootDirectory,
                query: query,
                childProvider: FileExplorerDirectoryLister.listChildren(of:)
            )
            Task { @MainActor [weak self] in
                guard let self, self.filterGeneration == requestGeneration else {
                    return
                }
                self.filterMatchItems = matches.map {
                    TerminalFileExplorerOutlineItem(node: $0.node, filterDisplayPath: $0.relativeDisplayPath)
                }
                self.outlineView.reloadData()
            }
        }
    }

    // MARK: Interactions

    @objc private func refreshClicked(_ sender: Any?) {
        agentSessionIndexStore.refresh()
        invalidateProjectIconSources()
        refresh()
    }

    private func invalidateProjectIconSources() {
        projectIconResolutionTask?.cancel()
        projectIconResolutionTask = nil
        projectIconSourceCache.removeAll()
        resolvedProjectIconURLs.removeAll()
        FileExplorerProjectIconLoader.shared.invalidate()
    }

    @objc private func agentSessionIndexDidChange(_ notification: Notification) {
        agentProvenance = agentSessionIndexStore.provenance
        outlineView.reloadData()
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let item = clickedOrSelectedItem() else {
            return
        }
        if item.node.kind == .file {
            callbacks.openFile(item.node.url)
            return
        }
        guard item.isExpandable else {
            return
        }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let item = clickedOrSelectedItem(),
              item.node.kind == .file,
              FileExplorerIcon.isImageFile(item.node)
        else {
            return
        }
        callbacks.openFile(item.node.url)
    }

    private func clickedOrSelectedItem() -> TerminalFileExplorerOutlineItem? {
        let clickedRow = outlineView.clickedRow
        if clickedRow >= 0,
           let clicked = outlineView.item(atRow: clickedRow) as? TerminalFileExplorerOutlineItem {
            return clicked
        }
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0 else {
            return nil
        }
        return outlineView.item(atRow: selectedRow) as? TerminalFileExplorerOutlineItem
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let readingEntries: [(L10nKey, Selector)] = [
            (.open, #selector(openFromContextMenu(_:))),
            (.revealInFinder, #selector(revealFromContextMenu(_:))),
            (.copyPath, #selector(copyPathFromContextMenu(_:))),
            (.insertPathIntoTerminal, #selector(insertPathFromContextMenu(_:))),
            // Only meaningful for a file an agent wrote; `menuNeedsUpdate`
            // disables it otherwise rather than presenting a dead action.
            (.revealTranscriptInFinder, #selector(revealAgentTranscriptFromContextMenu(_:))),
        ]
        for (key, action) in readingEntries {
            let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        // The items above read; everything below writes. A separator between
        // them is the only thing keeping a slip aimed at Copy Path off Rename.
        menu.addItem(.separator())
        let writingEntries: [(L10nKey, Selector)] = [
            (.fileExplorerNewFile, #selector(newFileFromContextMenu(_:))),
            (.fileExplorerNewFolder, #selector(newFolderFromContextMenu(_:))),
            (.fileExplorerRenameEntry, #selector(renameFromContextMenu(_:))),
        ]
        for (key, action) in writingEntries {
            let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        // Trash is separated again and last, the position every Finder-like
        // menu gives the one action that removes something.
        menu.addItem(.separator())
        let trashItem = NSMenuItem(
            title: AppLocalization.string(.fileExplorerMoveToTrash),
            action: #selector(moveToTrashFromContextMenu(_:)),
            keyEquivalent: ""
        )
        trashItem.target = self
        menu.addItem(trashItem)
        applyKeyEquivalents(in: menu)
        return menu
    }

    /// The shortcuts are shown beside their actions for discoverability. They
    /// are not what makes the keys work — a contextual menu's key equivalents
    /// only fire while that menu is open — so `TerminalFileExplorerOutlineView`
    /// carries the working bindings and these two must stay in step with it.
    private func applyKeyEquivalents(in menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(renameFromContextMenu(_:)):
                item.keyEquivalent = "\r"
                item.keyEquivalentModifierMask = []
            case #selector(moveToTrashFromContextMenu(_:)):
                item.keyEquivalent = String(UnicodeScalar(NSBackspaceCharacter)!)
                item.keyEquivalentModifierMask = .command
            default:
                continue
            }
        }
    }

    @objc private func openFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem() else {
            return
        }
        callbacks.openFile(item.node.url)
    }

    @objc private func revealFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem() else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.node.url])
    }

    @objc private func copyPathFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.node.url.path, forType: .string)
    }

    @objc private func insertPathFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem() else {
            return
        }
        callbacks.insertPath(item.node.url.path)
    }

    /// Opens Finder on the transcript that recorded the newest agent write to
    /// this file: the reveal path from "an agent changed this" to the session
    /// and prompt that did it.
    @objc private func revealAgentTranscriptFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem(),
              let touch = agentProvenance.mostRecentTouch(forAbsolutePath: item.node.url.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: touch.transcriptPath)])
    }

    /// Whether the clicked or selected row has an agent transcript to reveal.
    private func hasAgentTranscript(for item: TerminalFileExplorerOutlineItem?) -> Bool {
        guard let item else {
            return false
        }
        return agentProvenance.mostRecentTouch(forAbsolutePath: item.node.url.path) != nil
    }

    // MARK: Entry actions

    @objc private func newFileFromContextMenu(_ sender: Any?) {
        promptAndCreate(.newFile)
    }

    @objc private func newFolderFromContextMenu(_ sender: Any?) {
        promptAndCreate(.newFolder)
    }

    @objc private func renameFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem(),
              FileExplorerEntryAction.rename.isAvailable(in: entryActionContext(for: item))
        else {
            return
        }
        entryActions.promptAndRename(item.node.url)
    }

    @objc private func moveToTrashFromContextMenu(_ sender: Any?) {
        guard let item = clickedOrSelectedItem(),
              FileExplorerEntryAction.moveToTrash.isAvailable(in: entryActionContext(for: item))
        else {
            return
        }
        entryActions.moveToTrash(item.node.url)
    }

    private func promptAndCreate(_ action: FileExplorerEntryAction) {
        let selectedItem = clickedOrSelectedItem()
        guard let rootDirectory, action.isAvailable(in: entryActionContext(for: selectedItem)) else {
            return
        }
        entryActions.promptAndCreate(
            action,
            in: FileExplorerCreationTarget.directory(
                forSelectedNode: selectedItem?.node,
                rootDirectory: rootDirectory
            )
        )
    }

    /// The single place a write's outcome reaches the tree.
    ///
    /// Both outcomes re-list from disk, and the panel never inserts, renames,
    /// or removes a row itself. That is what keeps this from racing its own
    /// watcher: `refresh()` rebuilds every loaded directory from
    /// `contentsOfDirectory`, so running it here and again when the watcher's
    /// debounce fires converges on the same tree rather than adding the new row
    /// twice — and a failed write cannot leave a row on screen for a path that
    /// is no longer there.
    private func applyOutcome(revealing url: URL?, failure: FileExplorerEntryFailure?) {
        actionErrorRow.present(failure.map { FileExplorerEntryFailureCopy.message(for: $0) })
        refresh()
        guard let url else {
            return
        }
        revealAndSelect(url)
    }

    /// Expands the directories between the root and `url`, then selects it. A
    /// create inside a folder the user had collapsed would otherwise look like
    /// nothing happened.
    private func revealAndSelect(_ url: URL) {
        // The filtered list is flat and holds only search results, so there is
        // no chain to expand and the new row may not belong in it at all.
        guard filterMatchItems == nil, let rootDirectory, let rootItem else {
            return
        }
        let rootComponents = rootDirectory.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents
        else {
            return
        }
        let chain = rootItem.chain(toPathComponents: targetComponents[rootComponents.count...])
        guard let target = chain.last else {
            return
        }
        for ancestor in chain.dropLast() {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: target)
        guard row >= 0 else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    /// Gathers the disk facts `FileExplorerEntryAction` judges. Kept in one
    /// place so the menu, the shortcuts, and the handlers cannot disagree about
    /// when a write is legal.
    private func entryActionContext(
        for item: TerminalFileExplorerOutlineItem?
    ) -> FileExplorerEntryActionContext {
        guard let rootDirectory, remoteLocation == nil else {
            return FileExplorerEntryActionContext(
                isRemote: remoteLocation != nil,
                hasRootDirectory: rootDirectory != nil,
                hasSelection: item != nil,
                selectionExists: false,
                isCreationDirectoryWritable: false,
                isSelectionDirectoryWritable: false
            )
        }
        let fileManager = FileManager.default
        let creationDirectory = FileExplorerCreationTarget.directory(
            forSelectedNode: item?.node,
            rootDirectory: rootDirectory
        )
        let selectionDirectory = item?.node.url.deletingLastPathComponent()
        return FileExplorerEntryActionContext(
            isRemote: false,
            hasRootDirectory: true,
            hasSelection: item != nil,
            selectionExists: item.map { fileManager.fileExists(atPath: $0.node.url.path) } ?? false,
            isCreationDirectoryWritable: fileManager.isWritableFile(atPath: creationDirectory.path),
            isSelectionDirectoryWritable: selectionDirectory
                .map { fileManager.isWritableFile(atPath: $0.path) } ?? false
        )
    }

}

// MARK: - Outline data source / delegate

extension TerminalFileExplorerPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let filterMatchItems {
            return item == nil ? filterMatchItems.count : 0
        }
        guard let item else {
            return rootItem?.childItems().count ?? 0
        }
        guard let outlineItem = item as? TerminalFileExplorerOutlineItem, outlineItem.isExpandable else {
            return 0
        }
        return outlineItem.childItems().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let filterMatchItems, item == nil {
            return filterMatchItems[index]
        }
        guard let item else {
            return rootItem?.childItems()[index] as Any
        }
        let outlineItem = item as! TerminalFileExplorerOutlineItem
        return outlineItem.childItems()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard filterMatchItems == nil,
              let outlineItem = item as? TerminalFileExplorerOutlineItem
        else {
            return false
        }
        return outlineItem.isExpandable
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        DesignTokens.Component.fileExplorerRowHeightPX
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = TerminalFileExplorerSidebarRowView()
        rowView.chromeTheme = chromeTheme
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let outlineItem = item as? TerminalFileExplorerOutlineItem else {
            return nil
        }
        let absolutePath = outlineItem.node.url.path
        return TerminalFileExplorerRowCellView(
            item: outlineItem,
            badge: gitOverlay.badge(forAbsolutePath: absolutePath),
            agentMarker: FileExplorerAgentMarker.make(
                absolutePath: absolutePath,
                provenance: agentProvenance,
                now: Date()
            ),
            projectIconSource: projectIconSource(for: outlineItem),
            chromeTheme: chromeTheme
        )
    }

    private func projectIconSource(
        for item: TerminalFileExplorerOutlineItem
    ) -> FileExplorerProjectIconSource? {
        guard filterMatchItems == nil,
              item.node.kind == .directory,
              item.node.url.deletingLastPathComponent().standardizedFileURL.path
                == rootDirectory?.standardizedFileURL.path
        else {
            return nil
        }
        return projectIconSourceCache[item.node.url.standardizedFileURL]
    }

    private func resolveProjectIconsIfNeeded(
        in items: [TerminalFileExplorerOutlineItem],
        rootDirectory: URL
    ) {
        let unresolvedURLs = items.compactMap { item -> URL? in
            guard item.node.kind == .directory else { return nil }
            let url = item.node.url.standardizedFileURL
            return resolvedProjectIconURLs.contains(url) ? nil : url
        }
        guard !unresolvedURLs.isEmpty, projectIconResolutionTask == nil else { return }
        resolvedProjectIconURLs.formUnion(unresolvedURLs)
        projectIconResolutionTask = Task { [weak self] in
            let resolved = await FileExplorerProjectIconResolver.sources(for: unresolvedURLs)
            guard !Task.isCancelled,
                  let self,
                  self.rootDirectory == rootDirectory
            else {
                return
            }
            for (url, source) in resolved {
                if let source {
                    projectIconSourceCache[url] = source
                } else {
                    projectIconSourceCache.removeValue(forKey: url)
                }
            }
            outlineView.reloadData()
            projectIconResolutionTask = nil
            if let rootItem {
                resolveProjectIconsIfNeeded(
                    in: rootItem.childItems(),
                    rootDirectory: rootDirectory
                )
            }
        }
    }
}

extension TerminalFileExplorerPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let item = clickedOrSelectedItem()
        let hasTranscript = hasAgentTranscript(for: item)
        // Built once per opening: every writable action asks the same rule, and
        // the rule's inputs are filesystem calls worth making one time.
        let actionContext = entryActionContext(for: item)
        for menuItem in menu.items {
            if let action = Self.entryAction(for: menuItem) {
                menuItem.isEnabled = action.isAvailable(in: actionContext)
                continue
            }
            guard menuItem.action == #selector(revealAgentTranscriptFromContextMenu(_:)) else {
                menuItem.isEnabled = item != nil
                continue
            }
            menuItem.isEnabled = hasTranscript
        }
    }

    /// `nil` for the reading half of the menu and for separators.
    private static func entryAction(for menuItem: NSMenuItem) -> FileExplorerEntryAction? {
        switch menuItem.action {
        case #selector(newFileFromContextMenu(_:)):
            return .newFile
        case #selector(newFolderFromContextMenu(_:)):
            return .newFolder
        case #selector(renameFromContextMenu(_:)):
            return .rename
        case #selector(moveToTrashFromContextMenu(_:)):
            return .moveToTrash
        default:
            return nil
        }
    }
}
