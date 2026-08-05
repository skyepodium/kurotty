import AppKit

/// Right-side file-explorer panel showing the current working directory as a
/// lazy tree with git badges, name filtering, and a coalesced root watcher.
///
/// Wiring contract: instantiate, assign `callbacks`, call
/// `update(rootDirectory:)` when the tracked directory changes, and forward
/// theme changes through `applyChromeTheme(_:)`.

// MARK: - Callbacks

struct TerminalFileExplorerCallbacks {
    var openFile: (URL) -> Void
    var insertPath: (String) -> Void

    init(
        openFile: @escaping (URL) -> Void = { _ in },
        insertPath: @escaping (String) -> Void = { _ in }
    ) {
        self.openFile = openFile
        self.insertPath = insertPath
    }
}

// MARK: - Outline item

/// Reference wrapper around `FileExplorerNode` so `NSOutlineView` keeps stable
/// item identity (and expansion state) across refreshes. Children are listed
/// lazily on first expansion; refresh re-lists only already-loaded subtrees.
@MainActor
final class TerminalFileExplorerOutlineItem {
    let node: FileExplorerNode
    /// Non-nil only for flat filter-result rows.
    let filterDisplayPath: String?
    private(set) var loadedChildItems: [TerminalFileExplorerOutlineItem]?

    init(node: FileExplorerNode, filterDisplayPath: String? = nil) {
        self.node = node
        self.filterDisplayPath = filterDisplayPath
    }

    var isExpandable: Bool {
        filterDisplayPath == nil && node.kind == .directory && !node.isGitDirectory
    }

    func childItems() -> [TerminalFileExplorerOutlineItem] {
        if let loadedChildItems {
            return loadedChildItems
        }
        let children = FileExplorerDirectoryLister.listChildren(of: node.url)
            .map { TerminalFileExplorerOutlineItem(node: $0) }
        loadedChildItems = children
        return children
    }

    /// Re-lists every already-loaded directory, reusing existing item objects
    /// for unchanged paths so outline expansion state survives reloads.
    /// Never loads directories the user has not expanded.
    func refreshLoadedSubtree() {
        guard let existingChildren = loadedChildItems else {
            return
        }
        var existingByPath: [String: TerminalFileExplorerOutlineItem] = [:]
        for child in existingChildren {
            existingByPath[child.node.url.path] = child
        }
        loadedChildItems = FileExplorerDirectoryLister.listChildren(of: node.url).map { node in
            guard let reused = existingByPath[node.url.path], reused.node == node else {
                return TerminalFileExplorerOutlineItem(node: node)
            }
            reused.refreshLoadedSubtree()
            return reused
        }
    }
}

// MARK: - Root watcher

/// Coalesced `DispatchSource` watcher on the panel's root directory. The
/// source is scheduled on the main queue, so its handlers run on the main
/// actor; changes are debounced before invoking `onChange`.
@MainActor
final class TerminalFileExplorerRootWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pendingChange: DispatchWorkItem?
    private let onChange: () -> Void

    init?(directoryURL: URL, onChange: @escaping () -> Void) {
        let fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return nil
        }
        self.onChange = onChange
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .link],
            queue: .main
        )
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.setEventHandler { [weak self] in
            // Safe: this source is scheduled on DispatchQueue.main, so the
            // event handler always executes on the main actor.
            MainActor.assumeIsolated {
                self?.scheduleCoalescedChange()
            }
        }
        source.resume()
    }

    deinit {
        // The pending debounce work item only holds `self` weakly, so it
        // no-ops after deallocation; cancelling the source closes the fd.
        source.cancel()
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source.cancel()
    }

    private func scheduleCoalescedChange() {
        pendingChange?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Safe: the work item is enqueued on DispatchQueue.main below.
            MainActor.assumeIsolated {
                self?.onChange()
            }
        }
        pendingChange = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(AppConstants.FileExplorer.watcherDebounceMS),
            execute: workItem
        )
    }
}

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
    private var filterGeneration = 0
    private let gitStatusService = TerminalGitStatusService()
    /// Read-only source of "which agent wrote this file, from which prompt".
    /// The explorer never scans transcripts itself; it renders whatever the
    /// shared index already holds and asks it to rescan only on an explicit
    /// user action or a root change.
    private let agentSessionIndexStore: AgentSessionIndexStore
    private var agentProvenance = AgentFileProvenanceIndex.empty

    private let panelTitleLabel = NSTextField(labelWithString: "")
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
    private let listContainerView = NSView()
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyStateIconView = NSImageView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")

    init(agentSessionIndexStore: AgentSessionIndexStore = .shared) {
        self.agentSessionIndexStore = agentSessionIndexStore
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
        if remoteLocation != nil {
            remoteLocation = nil
            self.rootDirectory = nil
            updateRemoteEmptyState()
        }
        if self.rootDirectory != standardized {
            self.rootDirectory = standardized
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
        filterMatchItems = nil
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
        outlineView.reloadData()
        reapplyFilterIfNeeded()
        gitStatusService.requestStatus(rootDirectory: rootDirectory) { [weak self] result in
            self?.applyGitStatus(result)
        }
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.topChromeBackground.cgColor
        DesignTokens.Typography.rowTitleSel.apply(to: directoryNameLabel, color: theme.textPrimary)
        DesignTokens.Typography.sectionHeader.apply(to: panelTitleLabel, color: theme.textTertiary)
        searchPillView.applyChromeTheme(theme)
        refreshButton.applyChromeTheme(theme)
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

    // MARK: Setup

    private func configureSubviews() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor

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

        listContainerView.wantsLayer = true
        listContainerView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        listContainerView.clipsToBounds = true
        listContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listContainerView)

        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
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
        outlineView.menu = makeContextMenu()
    }

    private func activateLayoutConstraints() {
        let insetX = DesignTokens.Component.fileExplorerPanelInsetXPX
        let insetY = DesignTokens.Component.fileExplorerPanelInsetYPX
        let controlGap = DesignTokens.Component.fileExplorerControlGapPX
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
                equalTo: searchPillView.bottomAnchor,
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
        refresh()
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
        let entries: [(L10nKey, Selector)] = [
            (.open, #selector(openFromContextMenu(_:))),
            (.revealInFinder, #selector(revealFromContextMenu(_:))),
            (.copyPath, #selector(copyPathFromContextMenu(_:))),
            (.insertPathIntoTerminal, #selector(insertPathFromContextMenu(_:))),
            // Only meaningful for a file an agent wrote; `menuNeedsUpdate`
            // disables it otherwise rather than presenting a dead action.
            (.revealTranscriptInFinder, #selector(revealAgentTranscriptFromContextMenu(_:))),
        ]
        for (key, action) in entries {
            let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
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
            chromeTheme: chromeTheme
        )
    }
}

extension TerminalFileExplorerPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let item = clickedOrSelectedItem()
        let hasTranscript = hasAgentTranscript(for: item)
        for menuItem in menu.items {
            guard menuItem.action == #selector(revealAgentTranscriptFromContextMenu(_:)) else {
                menuItem.isEnabled = item != nil
                continue
            }
            menuItem.isEnabled = hasTranscript
        }
    }
}
