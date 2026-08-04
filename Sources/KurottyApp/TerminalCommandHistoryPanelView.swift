import AppKit

/// Reference-type wrappers because NSOutlineView tracks items by object
/// identity. Rebuilt on every reload; expansion state lives in the panel.
@MainActor
final class TerminalCommandHistoryGroupOutlineItem: NSObject {
    let group: TerminalCommandHistoryPanelGroup
    let commandItems: [TerminalCommandHistoryCommandOutlineItem]

    init(group: TerminalCommandHistoryPanelGroup) {
        self.group = group
        commandItems = group.entriesNewestFirst.map(TerminalCommandHistoryCommandOutlineItem.init)
    }
}

@MainActor
final class TerminalCommandHistoryCommandOutlineItem: NSObject {
    let entry: TerminalCommandHistoryEntry

    init(entry: TerminalCommandHistoryEntry) {
        self.entry = entry
    }
}

/// macOS source-list style sidebar listing recorded commands grouped by
/// working directory as expandable outline nodes. Selection and
/// Enter/double-click insert the command text into the active terminal prompt
/// without executing it; running again always routes through the explicit
/// replay-approval flow owned by the window controller.
@MainActor
final class TerminalCommandHistoryPanelView: NSView {
    private enum Symbol {
        static let emptyState = "clock.arrow.circlepath"
    }

    var onInsertCommand: ((TerminalCommandHistoryEntry) -> Void)?
    var onRunCommand: ((TerminalCommandHistoryEntry) -> Void)?

    private let store: TerminalCommandHistoryStore
    private let searchPillView = NSView()
    private let filterField = NSSearchField()
    private let sectionHeaderLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let outlineView = TerminalCommandHistoryOutlineView()
    private let emptyStateIconView = NSImageView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private var groupItems: [TerminalCommandHistoryGroupOutlineItem] = []
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    /// In-memory per-window record of user disclosure toggles keyed by
    /// directory path. Absent paths fall back to the recency default.
    private var explicitExpansionByPath: [String: Bool] = [:]
    private var isApplyingExpansionState = false

    init(store: TerminalCommandHistoryStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        configure()
        observeStore()
        reloadGroups()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.topChromeBackground.cgColor
        searchPillView.layer?.backgroundColor = theme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandHistorySearchPillBackgroundAlphaRATIO)
            .cgColor
        filterField.textColor = theme.textPrimary
        sectionHeaderLabel.textColor = theme.textMuted
        emptyStateIconView.contentTintColor = theme.textMuted
        emptyStateLabel.textColor = theme.textMuted
        outlineView.reloadData()
        applyExpansionState()
    }

    func focusFilterField() {
        window?.makeFirstResponder(filterField)
    }

    var visibleGroupsForTesting: [TerminalCommandHistoryPanelGroup] {
        groupItems.map(\.group)
    }

    func isGroupExpandedForTesting(path: String) -> Bool {
        guard let item = groupItems.first(where: { $0.group.display.path == path }) else {
            return false
        }
        return outlineView.isItemExpanded(item)
    }

    // MARK: - Configuration

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor
        configureSearchPill()
        configureSectionHeader()
        configureOutline()
        configureEmptyState()
        activateLayoutConstraints()
    }

    private func configureSearchPill() {
        searchPillView.wantsLayer = true
        searchPillView.layer?.cornerRadius = DesignTokens.Component.commandHistorySearchPillCornerRadiusPX
        searchPillView.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandHistorySearchPillBackgroundAlphaRATIO)
            .cgColor
        searchPillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchPillView)

        filterField.placeholderString = AppLocalization.string(.commandHistoryFilterPlaceholder)
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.sendsSearchStringImmediately = true
        filterField.sendsWholeSearchString = false
        filterField.font = NSFont.systemFont(ofSize: DesignTokens.Typography.sidebarSearchFontSizePT)
        filterField.isBezeled = false
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.translatesAutoresizingMaskIntoConstraints = false
        searchPillView.addSubview(filterField)
    }

    private func configureSectionHeader() {
        sectionHeaderLabel.stringValue = AppLocalization.string(.commandHistorySectionTitle).localizedUppercase
        sectionHeaderLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Typography.sidebarSectionHeaderFontSizePT,
            weight: .semibold
        )
        sectionHeaderLabel.textColor = chromeTheme.textMuted
        sectionHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionHeaderLabel)
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero
        outlineView.allowsMultipleSelection = false
        outlineView.indentationPerLevel = DesignTokens.Component.commandHistoryOutlineIndentationPX
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autoresizesOutlineColumn = false
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.onReturnKey = { [weak self] in
            self?.insertSelectedCommand()
        }
        outlineView.menu = makeContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
    }

    private func configureEmptyState() {
        emptyStateIconView.image = NSImage(systemSymbolName: Symbol.emptyState, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: DesignTokens.Component.commandHistoryEmptyStateIconPointSizePT,
                weight: .regular
            ))
        emptyStateIconView.contentTintColor = chromeTheme.textMuted
        emptyStateIconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStateIconView)

        emptyStateLabel.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT)
        emptyStateLabel.textColor = chromeTheme.textMuted
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStateLabel)
    }

    private func activateLayoutConstraints() {
        let insetX = DesignTokens.Component.commandHistoryPanelInsetXPX
        let insetY = DesignTokens.Component.commandHistoryPanelInsetYPX
        let pillTextInset = DesignTokens.Component.commandHistorySearchPillTextInsetXPX
        NSLayoutConstraint.activate([
            sectionHeaderLabel.topAnchor.constraint(equalTo: topAnchor, constant: insetY),
            sectionHeaderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderInsetXPX
            ),
            sectionHeaderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -insetX
            ),

            searchPillView.topAnchor.constraint(
                equalTo: sectionHeaderLabel.bottomAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderBottomGapPX
            ),
            searchPillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            searchPillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
            searchPillView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.commandHistorySearchPillHeightPX
            ),

            filterField.leadingAnchor.constraint(equalTo: searchPillView.leadingAnchor, constant: pillTextInset),
            filterField.trailingAnchor.constraint(equalTo: searchPillView.trailingAnchor, constant: -pillTextInset),
            filterField.centerYAnchor.constraint(equalTo: searchPillView.centerYAnchor),

            scrollView.topAnchor.constraint(
                equalTo: searchPillView.bottomAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderTopGapPX
            ),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyStateIconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateIconView.bottomAnchor.constraint(
                equalTo: emptyStateLabel.topAnchor,
                constant: -DesignTokens.Component.commandHistoryEmptyStateGapPX
            ),
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: insetX),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insetX),
        ])
    }

    // MARK: - Data

    private func observeStore() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: TerminalCommandHistoryStore.didChangeNotification,
            object: store
        )
    }

    @objc private func storeDidChange(_ notification: Notification) {
        reloadGroups()
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        reloadGroups()
    }

    private func reloadGroups() {
        let groups = TerminalCommandHistoryRowBuilder.groups(
            entriesNewestFirst: store.entriesNewestFirst,
            filter: filterField.stringValue
        )
        groupItems = groups.map(TerminalCommandHistoryGroupOutlineItem.init)
        updateEmptyState()
        outlineView.reloadData()
        applyExpansionState()
    }

    /// Applies remembered disclosure state; groups without an explicit user
    /// toggle default to expanded for the most recent
    /// `commandHistoryDefaultExpandedGroupCount` directories. While a filter
    /// is active every match is shown expanded without disturbing the
    /// remembered state.
    private func applyExpansionState() {
        isApplyingExpansionState = true
        defer { isApplyingExpansionState = false }
        let isFiltering = !filterField.stringValue.isEmpty
        for (index, item) in groupItems.enumerated() {
            let expandedByDefault = index < DesignTokens.Component.commandHistoryDefaultExpandedGroupCount
            let isExpanded = isFiltering
                ? true
                : explicitExpansionByPath[item.group.display.path] ?? expandedByDefault
            if isExpanded {
                outlineView.expandItem(item)
            } else {
                outlineView.collapseItem(item)
            }
        }
    }

    private func updateEmptyState() {
        if !store.isRecordingEnabled, store.entryCount == 0 {
            emptyStateLabel.stringValue = AppLocalization.string(.commandHistoryDisabledExplanation)
        } else {
            emptyStateLabel.stringValue = AppLocalization.string(.commandHistoryEmpty)
        }
        let isEmpty = groupItems.isEmpty
        emptyStateIconView.isHidden = !isEmpty
        emptyStateLabel.isHidden = !isEmpty
    }

    // MARK: - Interactions

    private func entry(atRow row: Int) -> TerminalCommandHistoryEntry? {
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? TerminalCommandHistoryCommandOutlineItem
        else {
            return nil
        }
        return item.entry
    }

    private func selectedEntry() -> TerminalCommandHistoryEntry? {
        entry(atRow: outlineView.selectedRow)
    }

    private func clickedOrSelectedEntry() -> TerminalCommandHistoryEntry? {
        if let clicked = entry(atRow: outlineView.clickedRow) {
            return clicked
        }
        return selectedEntry()
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let groupItem = outlineView.item(atRow: outlineView.clickedRow)
            as? TerminalCommandHistoryGroupOutlineItem
        else {
            return
        }
        if outlineView.isItemExpanded(groupItem) {
            outlineView.animator().collapseItem(groupItem)
        } else {
            outlineView.animator().expandItem(groupItem)
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let entry = clickedOrSelectedEntry() else {
            return
        }
        onInsertCommand?(entry)
    }

    private func insertSelectedCommand() {
        guard let entry = selectedEntry() else {
            return
        }
        onInsertCommand?(entry)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let entries: [(L10nKey, Selector)] = [
            (.insertIntoTerminal, #selector(insertFromContextMenu(_:))),
            (.runAgain, #selector(runAgainFromContextMenu(_:))),
            (.copyCommand, #selector(copyCommandFromContextMenu(_:))),
            (.copyChangeDirectoryCommand, #selector(copyChangeDirectoryFromContextMenu(_:))),
            (.revealDirectoryInFinder, #selector(revealDirectoryFromContextMenu(_:))),
        ]
        for (key, action) in entries {
            let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func insertFromContextMenu(_ sender: Any?) {
        guard let entry = clickedOrSelectedEntry() else {
            return
        }
        onInsertCommand?(entry)
    }

    @objc private func runAgainFromContextMenu(_ sender: Any?) {
        guard let entry = clickedOrSelectedEntry() else {
            return
        }
        onRunCommand?(entry)
    }

    @objc private func copyCommandFromContextMenu(_ sender: Any?) {
        guard let entry = clickedOrSelectedEntry() else {
            return
        }
        copyToPasteboard(entry.commandText)
    }

    @objc private func copyChangeDirectoryFromContextMenu(_ sender: Any?) {
        guard let cwd = clickedOrSelectedEntry()?.cwd, !cwd.isEmpty else {
            return
        }
        copyToPasteboard("cd \(shellQuotedPath(cwd))")
    }

    @objc private func revealDirectoryFromContextMenu(_ sender: Any?) {
        guard let cwd = clickedOrSelectedEntry()?.cwd, !cwd.isEmpty else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Single-quote shell quoting so pasted `cd` commands survive spaces and
    /// metacharacters in directory names.
    private func shellQuotedPath(_ path: String) -> String {
        TerminalShellPathQuoting.quoted(path)
    }
}

// MARK: - Outline data source / delegate

extension TerminalCommandHistoryPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let groupItem = item as? TerminalCommandHistoryGroupOutlineItem else {
            return groupItems.count
        }
        return groupItem.commandItems.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let groupItem = item as? TerminalCommandHistoryGroupOutlineItem else {
            return groupItems[index]
        }
        return groupItem.commandItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TerminalCommandHistoryGroupOutlineItem
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is TerminalCommandHistoryCommandOutlineItem
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard item is TerminalCommandHistoryGroupOutlineItem else {
            return DesignTokens.Component.commandHistoryCommandRowHeightPX
        }
        return DesignTokens.Component.commandHistoryGroupRowHeightPX
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = TerminalCommandHistorySidebarRowView()
        rowView.hoverBackgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.commandHistoryHoverBackgroundAlphaRATIO)
        rowView.selectionBackgroundColor = chromeTheme.activeIndicator
            .withAlphaComponent(DesignTokens.Component.commandHistorySelectionBackgroundAlphaRATIO)
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let groupItem = item as? TerminalCommandHistoryGroupOutlineItem {
            return TerminalCommandHistoryGroupCellView(group: groupItem.group, chromeTheme: chromeTheme)
        }
        guard let commandItem = item as? TerminalCommandHistoryCommandOutlineItem else {
            return nil
        }
        return TerminalCommandHistoryCommandCellView(
            entry: commandItem.entry,
            chromeTheme: chromeTheme,
            now: Date()
        )
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        recordUserDisclosureToggle(notification, isExpanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        recordUserDisclosureToggle(notification, isExpanded: false)
    }

    private func recordUserDisclosureToggle(_ notification: Notification, isExpanded: Bool) {
        guard !isApplyingExpansionState,
              filterField.stringValue.isEmpty,
              let groupItem = notification.userInfo?["NSObject"] as? TerminalCommandHistoryGroupOutlineItem
        else {
            return
        }
        explicitExpansionByPath[groupItem.group.display.path] = isExpanded
    }
}

extension TerminalCommandHistoryPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let entry = clickedOrSelectedEntry()
        let hasEntry = entry != nil
        let hasDirectory = !(entry?.cwd ?? "").isEmpty
        for item in menu.items {
            switch item.action {
            case #selector(copyChangeDirectoryFromContextMenu(_:)), #selector(revealDirectoryFromContextMenu(_:)):
                item.isEnabled = hasDirectory
            default:
                item.isEnabled = hasEntry
            }
        }
    }
}
