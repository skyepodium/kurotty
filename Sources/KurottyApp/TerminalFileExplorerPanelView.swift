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
    static let contentInsetPX: CGFloat = 8
    static let headerControlGapPX: CGFloat = 6
    static let refreshButtonSizePX: CGFloat = 22
    static let searchModeControlGapPX: CGFloat = 6
    static let rowHeightPX: CGFloat = 26
    static let rowIconSizePX: CGFloat = 14
    static let rowGapPX: CGFloat = 6
    static let rowInsetXPX: CGFloat = 8
    static let badgeMinWidthPX: CGFloat = 14
    static let outlineIndentPX: CGFloat = 12
    static let dimmedAlphaRATIO: CGFloat = 0.55
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
    private var rootItem: TerminalFileExplorerOutlineItem?
    private var filterMatchItems: [TerminalFileExplorerOutlineItem]?
    private var gitOverlay = FileExplorerGitOverlay.empty
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var watcher: TerminalFileExplorerRootWatcher?
    private var filterGeneration = 0
    private let gitStatusService = TerminalGitStatusService()

    private let directoryNameLabel = NSTextField(labelWithString: "")
    private let refreshButton = ChromeIconButton(frame: .zero)
    private let searchField = NSSearchField()
    private let searchModeControl = NSSegmentedControl(
        labels: [
            FileExplorerL10n.string(.segmentName),
            FileExplorerL10n.string(.segmentContent),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

    init() {
        super.init(frame: .zero)
        configureSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Public API

    func update(rootDirectory: URL) {
        let standardized = rootDirectory.standardizedFileURL
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

    func refresh() {
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
        outlineView.reloadData()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: Setup

    private func configureSubviews() {
        wantsLayer = true
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor

        directoryNameLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Typography.labelFontSizePT,
            weight: .bold
        )
        directoryNameLabel.textColor = chromeTheme.textPrimary
        directoryNameLabel.lineBreakMode = .byTruncatingMiddle
        directoryNameLabel.maximumNumberOfLines = 1
        directoryNameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(directoryNameLabel)

        refreshButton.image = NSImage(
            systemSymbolName: FileExplorerIcon.refreshSymbolName,
            accessibilityDescription: FileExplorerL10n.string(.refresh)
        )
        refreshButton.toolTip = FileExplorerL10n.string(.refresh)
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)

        searchField.placeholderString = FileExplorerL10n.string(.searchPlaceholder)
        searchField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        // Content search is a v2 feature; keep the segment visible but
        // disabled so the layout matches the target design.
        searchModeControl.selectedSegment = 0
        searchModeControl.setEnabled(false, forSegment: 1)
        searchModeControl.segmentStyle = .roundRect
        searchModeControl.font = NSFont.systemFont(ofSize: DesignTokens.Typography.statusFontSizePT)
        searchModeControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchModeControl)

        configureOutlineView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        activateLayoutConstraints()
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = FileExplorerMetrics.outlineIndentPX
        outlineView.allowsMultipleSelection = false
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.menu = makeContextMenu()
    }

    private func activateLayoutConstraints() {
        let inset = FileExplorerMetrics.contentInsetPX
        NSLayoutConstraint.activate([
            directoryNameLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            directoryNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            directoryNameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: refreshButton.leadingAnchor,
                constant: -FileExplorerMetrics.headerControlGapPX
            ),

            refreshButton.centerYAnchor.constraint(equalTo: directoryNameLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            refreshButton.widthAnchor.constraint(equalToConstant: FileExplorerMetrics.refreshButtonSizePX),
            refreshButton.heightAnchor.constraint(equalToConstant: FileExplorerMetrics.refreshButtonSizePX),

            searchField.topAnchor.constraint(
                equalTo: directoryNameLabel.bottomAnchor,
                constant: FileExplorerMetrics.headerControlGapPX
            ),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            searchModeControl.topAnchor.constraint(
                equalTo: searchField.bottomAnchor,
                constant: FileExplorerMetrics.searchModeControlGapPX
            ),
            searchModeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),

            scrollView.topAnchor.constraint(
                equalTo: searchModeControl.bottomAnchor,
                constant: FileExplorerMetrics.searchModeControlGapPX
            ),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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

    @objc private func searchChanged(_ sender: NSSearchField) {
        reapplyFilterIfNeeded()
    }

    private func reapplyFilterIfNeeded() {
        filterGeneration += 1
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
        let entries: [(FileExplorerL10n.Key, Selector)] = [
            (.open, #selector(openFromContextMenu(_:))),
            (.revealInFinder, #selector(revealFromContextMenu(_:))),
            (.copyPath, #selector(copyPathFromContextMenu(_:))),
            (.insertPathIntoTerminal, #selector(insertPathFromContextMenu(_:))),
        ]
        for (key, action) in entries {
            let item = NSMenuItem(title: FileExplorerL10n.string(key), action: action, keyEquivalent: "")
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
        FileExplorerMetrics.rowHeightPX
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

extension TerminalFileExplorerPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let item = clickedOrSelectedItem()
        for menuItem in menu.items {
            menuItem.isEnabled = item != nil
        }
    }
}
