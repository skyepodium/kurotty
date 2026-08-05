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
// MARK: - Design metrics

enum FileExplorerMetrics {
    static let rowIconSizePX: CGFloat = 14
    static let rowGapPX: CGFloat = 6
    static let rowInsetXPX: CGFloat = 8
    static let badgeMinWidthPX: CGFloat = 14
    static let outlineIndentPX: CGFloat = 12
    static let dimmedAlphaRATIO: CGFloat = 0.55
    static let emptyStateIconAlphaRATIO: CGFloat = 0.66
    static let emptyStateLabelAlphaRATIO: CGFloat = 0.72
    static let watcherDebounceMS = 300
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
            deadline: .now() + .milliseconds(FileExplorerMetrics.watcherDebounceMS),
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

    private let panelTitleLabel = NSTextField(labelWithString: "")
    private let directoryNameLabel = NSTextField(labelWithString: "")
    private let refreshButton = ChromeIconButton(frame: .zero)
    private let searchPillView = NSView()
    // Own magnifier + plain text field: an unbezeled NSSearchField stops
    // insetting its text, so the placeholder overlapped the cell's built-in
    // search icon whenever the field was not being edited.
    private let searchIconView = NSImageView()
    private let searchField = NSTextField()
    private let listContainerView = NSView()
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let emptyStateIconView = NSImageView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        directoryNameLabel.textColor = theme.textPrimary
        panelTitleLabel.textColor = theme.textMuted
        searchPillView.layer?.backgroundColor = theme.textPrimary
            .withAlphaComponent(DesignTokens.Component.fileExplorerSearchPillBackgroundAlphaRATIO)
            .cgColor
        searchField.textColor = theme.textPrimary
        searchIconView.contentTintColor = theme.textMuted
        emptyStateIconView.contentTintColor = theme.textMuted
        emptyStateLabel.textColor = theme.textMuted
        applySearchPlaceholder()
        updateRemoteEmptyState()
        outlineView.reloadData()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
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
        searchField.isEnabled
    }

    // MARK: Setup

    private func configureSubviews() {
        wantsLayer = true
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor

        panelTitleLabel.stringValue = AppLocalization.string(.fileExplorer).localizedUppercase
        panelTitleLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Typography.sidebarSectionHeaderFontSizePT,
            weight: .semibold
        )
        panelTitleLabel.textColor = chromeTheme.textMuted
        panelTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panelTitleLabel)

        directoryNameLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Typography.sidebarGroupNameFontSizePT,
            weight: .semibold
        )
        directoryNameLabel.textColor = chromeTheme.textPrimary
        directoryNameLabel.lineBreakMode = .byTruncatingMiddle
        directoryNameLabel.maximumNumberOfLines = 1
        directoryNameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(directoryNameLabel)

        refreshButton.image = NSImage(
            systemSymbolName: FileExplorerIcon.refreshSymbolName,
            accessibilityDescription: AppLocalization.string(.refresh)
        )
        refreshButton.toolTip = AppLocalization.string(.refresh)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)

        searchPillView.wantsLayer = true
        searchPillView.layer?.cornerRadius = DesignTokens.Component.fileExplorerSearchPillCornerRadiusPX
        searchPillView.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.fileExplorerSearchPillBackgroundAlphaRATIO)
            .cgColor
        searchPillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchPillView)

        searchIconView.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: DesignTokens.Typography.sidebarSearchFontSizePT,
                weight: .regular
            )
        )
        searchIconView.contentTintColor = chromeTheme.textMuted
        searchIconView.imageScaling = .scaleNone
        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchPillView.addSubview(searchIconView)

        searchField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSearchFontSizePT)
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchPillView.addSubview(searchField)
        applySearchPlaceholder()

        listContainerView.wantsLayer = true
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

    /// Empty state for remote sessions. Lives inside the list container, so it
    /// occupies the tree region only and can never overlap the header or the
    /// search pill.
    private func configureRemoteEmptyState() {
        emptyStateIconView.image = NSImage(
            systemSymbolName: FileExplorerIcon.remoteSymbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Component.commandHistoryEmptyStateIconPointSizePT,
            weight: .regular
        ))
        emptyStateIconView.contentTintColor = chromeTheme.textMuted
        emptyStateIconView.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(emptyStateIconView)

        emptyStateLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.statusFontSizePT)
        emptyStateLabel.textColor = chromeTheme.textMuted
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
        searchField.isEnabled = !isRemote
        refreshButton.isEnabled = !isRemote
        emptyStateIconView.alphaValue = FileExplorerMetrics.emptyStateIconAlphaRATIO
        emptyStateLabel.alphaValue = FileExplorerMetrics.emptyStateLabelAlphaRATIO
        guard let remoteLocation else {
            emptyStateLabel.stringValue = ""
            return
        }
        searchField.stringValue = ""
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
        outlineView.indentationPerLevel = FileExplorerMetrics.outlineIndentPX
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
        let searchTextInset = DesignTokens.Component.fileExplorerSearchPillTextInsetXPX
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
            searchPillView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.fileExplorerSearchPillHeightPX
            ),

            searchIconView.leadingAnchor.constraint(equalTo: searchPillView.leadingAnchor, constant: searchTextInset),
            searchIconView.centerYAnchor.constraint(equalTo: searchPillView.centerYAnchor),

            searchField.leadingAnchor.constraint(
                equalTo: searchIconView.trailingAnchor,
                constant: DesignTokens.Component.commandHistorySearchIconGapPX
            ),
            searchField.trailingAnchor.constraint(equalTo: searchPillView.trailingAnchor, constant: -searchTextInset),
            searchField.centerYAnchor.constraint(equalTo: searchPillView.centerYAnchor),

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

    /// Explicit muted placeholder color so it reads correctly against the
    /// pill in both chrome themes.
    private func applySearchPlaceholder() {
        searchField.placeholderAttributedString = NSAttributedString(
            string: AppLocalization.string(.fileExplorerSearchPlaceholder),
            attributes: [
                .foregroundColor: chromeTheme.textMuted,
                .font: NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSearchFontSizePT),
            ]
        )
    }

    @objc private func searchChanged(_ sender: NSTextField) {
        reapplyFilterIfNeeded()
    }

    private func reapplyFilterIfNeeded() {
        filterGeneration += 1
        // No local tree to scan while the session is remote.
        guard remoteLocation == nil else {
            filterMatchItems = nil
            return
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
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
        refresh()
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
        let badge = gitOverlay.badge(forAbsolutePath: outlineItem.node.url.path)
        return TerminalFileExplorerRowCellView(
            item: outlineItem,
            badge: badge,
            chromeTheme: chromeTheme
        )
    }
}

extension TerminalFileExplorerPanelView: NSTextFieldDelegate {
    /// Filter as the user types, matching the previous search field's
    /// immediate-send behavior.
    func controlTextDidChange(_ notification: Notification) {
        reapplyFilterIfNeeded()
    }
}

extension TerminalFileExplorerPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let item = clickedOrSelectedItem()
        for menuItem in menu.items {
            menuItem.isEnabled = item != nil
        }
    }
}
