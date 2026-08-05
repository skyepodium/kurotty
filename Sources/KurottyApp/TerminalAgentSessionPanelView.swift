import AppKit

/// macOS source-list style sidebar listing AI coding-agent sessions that the
/// agents themselves stored on disk, grouped by project as expandable outline
/// nodes.
///
/// Safety contract: this panel has no execute path at all. Selection,
/// Enter, and double-click insert the resume command at the active prompt
/// without a trailing newline, so the user always presses Return themselves.
/// Every other action is copy/reveal only.
@MainActor
final class TerminalAgentSessionPanelView: NSView {
    var onInsertResumeCommand: ((AgentSessionRecord) -> Void)?
    var onOpenDirectoryInExplorer: ((AgentSessionRecord) -> Void)?
    /// Set by the host window controller, which opens the read-only viewer in a
    /// center tab. The panel itself never presents a viewer: it has no window to
    /// own one, so an unset handler simply means the action is unavailable.
    var onOpenTranscript: ((AgentSessionRecord) -> Void)?

    private let store: AgentSessionIndexStore
    private let homeDirectory: String
    /// Shared sidebar control; see `TerminalSidebarSearchPillView`.
    private let searchPillView = TerminalSidebarSearchPillView(
        placeholder: { AppLocalization.string(.agentSessionsFilterPlaceholder) }
    )
    private let sectionHeaderLabel = NSTextField(labelWithString: "")
    /// Clipping container for everything below the search pill. The scroll
    /// view and the empty state are both children of this view, so the empty
    /// state is centered in the list region instead of the whole panel and can
    /// never be drawn over the section header or the search pill.
    private let listContainerView = NSView()
    private let usageSummaryView = TerminalAgentUsageSummaryView()
    private let scrollView = NSScrollView()
    private let outlineView = TerminalCommandHistoryOutlineView()
    private let emptyStateIconView = NSImageView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private var groupItems: [TerminalAgentSessionGroupOutlineItem] = []
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    /// In-memory per-window record of user disclosure toggles keyed by group
    /// path. Absent paths fall back to the recency default.
    private var explicitExpansionByPath: [String: Bool] = [:]
    private var isApplyingExpansionState = false

    init(
        store: AgentSessionIndexStore = .shared,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.store = store
        self.homeDirectory = homeDirectory
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
        searchPillView.applyChromeTheme(theme)
        usageSummaryView.applyChromeTheme(theme)
        DesignTokens.Typography.sectionHeader.apply(to: sectionHeaderLabel, color: theme.textTertiary)
        applyEmptyStateIcon(tint: theme.textMuted)
        emptyStateLabel.textColor = theme.textMuted
        emptyStateIconView.alphaValue = DesignTokens.Component.sidebarEmptyStateIconAlphaRATIO
        emptyStateLabel.alphaValue = DesignTokens.Component.sidebarEmptyStateLabelAlphaRATIO
        outlineView.reloadData()
        applyExpansionState()
    }

    func focusFilterField() {
        searchPillView.focus()
    }

    /// Called when the section becomes visible: indexing only ever runs on an
    /// explicit request, never on a timer.
    func refreshIndex() {
        store.refresh()
    }

    var visibleGroupsForTesting: [AgentSessionPanelGroup] {
        groupItems.map(\.group)
    }

    var emptyStateTextForTesting: String {
        emptyStateLabel.stringValue
    }

    /// Panel-relative union of the empty-state icon and label, so layout
    /// regression tests can compare it against the header, pill, and list
    /// frames without depending on the view hierarchy's nesting.
    var emptyStateFrameForTesting: NSRect {
        convert(emptyStateIconView.bounds, from: emptyStateIconView)
            .union(convert(emptyStateLabel.bounds, from: emptyStateLabel))
    }

    var emptyStateIsHiddenForTesting: Bool {
        emptyStateLabel.isHidden && emptyStateIconView.isHidden
    }

    var searchPillFrameForTesting: NSRect {
        convert(searchPillView.bounds, from: searchPillView)
    }

    var sectionHeaderFrameForTesting: NSRect {
        convert(sectionHeaderLabel.bounds, from: sectionHeaderLabel)
    }

    var listRegionFrameForTesting: NSRect {
        convert(listContainerView.bounds, from: listContainerView)
    }

    var emptyStateLabelFrameForTesting: NSRect {
        convert(emptyStateLabel.bounds, from: emptyStateLabel)
    }

    var emptyStateTextOverflowsFrameForTesting: Bool {
        TerminalSidebarEmptyStateLayout.textOverflowsFrame(label: emptyStateLabel)
    }

    // MARK: - Configuration

    private func configure() {
        wantsLayer = true
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor
        configureSearchPill()
        configureSectionHeader()
        configureListContainer()
        configureOutline()
        configureEmptyState()
        activateLayoutConstraints()
    }

    private func configureListContainer() {
        listContainerView.wantsLayer = true
        listContainerView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        listContainerView.clipsToBounds = true
        listContainerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listContainerView)
    }

    private func configureSearchPill() {
        searchPillView.onQueryChanged = { [weak self] in
            self?.reloadGroups()
        }
        searchPillView.applyChromeTheme(chromeTheme)
        searchPillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchPillView)

        usageSummaryView.translatesAutoresizingMaskIntoConstraints = false
        usageSummaryView.applyChromeTheme(chromeTheme)
        addSubview(usageSummaryView)
    }

    private func configureSectionHeader() {
        sectionHeaderLabel.stringValue = AppLocalization.string(.agentSessionsSectionTitle).localizedUppercase
        DesignTokens.Typography.sectionHeader.apply(
            to: sectionHeaderLabel,
            color: chromeTheme.textTertiary
        )
        sectionHeaderLabel.lineBreakMode = .byTruncatingTail
        sectionHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionHeaderLabel)
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("agentSession"))
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
            self?.insertSelectedResumeCommand()
        }
        outlineView.menu = makeContextMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(scrollView)
    }

    /// Palette-tinted symbols bake their color into the image, so a theme
    /// change has to rebuild the icon rather than reassign `contentTintColor`.
    private func applyEmptyStateIcon(tint: NSColor) {
        emptyStateIconView.image = Icon.symbol(
            IconSymbol.agentSessionEmptyState,
            pointSizePT: DesignTokens.Component.agentSessionEmptyStateIconPointSizePT,
            weight: .regular,
            tint: tint
        )
    }

    private func configureEmptyState() {
        applyEmptyStateIcon(tint: chromeTheme.textMuted)
        emptyStateIconView.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(emptyStateIconView)

        DesignTokens.Typography.rowTitle.apply(to: emptyStateLabel, color: chromeTheme.textMuted)
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        listContainerView.addSubview(emptyStateLabel)
    }

    private func activateLayoutConstraints() {
        let insetX = DesignTokens.Component.commandHistoryPanelInsetXPX
        let insetY = DesignTokens.Component.commandHistoryPanelInsetYPX
        NSLayoutConstraint.activate([
            sectionHeaderLabel.topAnchor.constraint(equalTo: topAnchor, constant: insetY),
            sectionHeaderLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderInsetXPX
            ),
            sectionHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insetX),

            searchPillView.topAnchor.constraint(
                equalTo: sectionHeaderLabel.bottomAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderBottomGapPX
            ),
            searchPillView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
            searchPillView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),

            usageSummaryView.topAnchor.constraint(
                equalTo: searchPillView.bottomAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderTopGapPX
            ),
            usageSummaryView.leadingAnchor.constraint(equalTo: leadingAnchor),
            usageSummaryView.trailingAnchor.constraint(equalTo: trailingAnchor),

            listContainerView.topAnchor.constraint(
                equalTo: usageSummaryView.bottomAnchor,
                constant: DesignTokens.Component.commandHistorySectionHeaderTopGapPX
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

    // MARK: - Data

    private func observeStore() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange(_:)),
            name: AgentSessionIndexStore.didChangeNotification,
            object: store
        )
    }

    @objc private func storeDidChange(_ notification: Notification) {
        reloadGroups()
    }

    /// Recomputed whenever the index changes so the strip tracks the same data
    /// the list shows. Hidden by itself when no session reports usage.
    private func refreshUsageSummary(records: [AgentSessionRecord]) {
        usageSummaryView.update(
            summary: AgentTokenUsageSummary.make(records: records, now: Date())
        )
    }

    private func reloadGroups() {
        let groups = AgentSessionRowBuilder.groups(
            records: store.records,
            filter: searchPillView.stringValue,
            homeDirectory: homeDirectory
        )
        groupItems = groups.map(TerminalAgentSessionGroupOutlineItem.init)
        // The strip summarizes the whole index, not the filtered view: a search
        // narrows which sessions you are looking at, not how much you spent.
        refreshUsageSummary(records: store.records)
        updateEmptyState()
        outlineView.reloadData()
        applyExpansionState()
    }

    /// Applies remembered disclosure state; groups without an explicit user
    /// toggle default to expanded for the most recent
    /// `agentSessionDefaultExpandedGroupCount` projects. While a filter is
    /// active every match is shown expanded without disturbing that state.
    private func applyExpansionState() {
        isApplyingExpansionState = true
        defer { isApplyingExpansionState = false }
        let isFiltering = !searchPillView.stringValue.isEmpty
        for (index, item) in groupItems.enumerated() {
            let expandedByDefault = index < DesignTokens.Component.agentSessionDefaultExpandedGroupCount
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
        if !store.isIndexingEnabled {
            emptyStateLabel.stringValue = AppLocalization.string(.agentSessionsDisabledExplanation)
        } else {
            emptyStateLabel.stringValue = AppLocalization.string(.agentSessionsEmpty)
        }
        let isEmpty = groupItems.isEmpty
        emptyStateIconView.isHidden = !isEmpty
        emptyStateLabel.isHidden = !isEmpty
    }

    // MARK: - Interactions

    private func record(atRow row: Int) -> AgentSessionRecord? {
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? TerminalAgentSessionOutlineItem
        else {
            return nil
        }
        return item.record
    }

    private func selectedRecord() -> AgentSessionRecord? {
        record(atRow: outlineView.selectedRow)
    }

    private func clickedOrSelectedRecord() -> AgentSessionRecord? {
        if let clicked = record(atRow: outlineView.clickedRow) {
            return clicked
        }
        return selectedRecord()
    }

    /// Opens the read-only transcript viewer. Never writes to a PTY and never
    /// resumes the session; resuming stays on the explicit insert path.
    func openTranscript(for record: AgentSessionRecord) {
        guard !record.filePath.isEmpty else {
            return
        }
        onOpenTranscript?(record)
    }

    @objc private func rowClicked(_ sender: Any?) {
        if let record = record(atRow: outlineView.clickedRow) {
            openTranscript(for: record)
            return
        }
        guard let groupItem = outlineView.item(atRow: outlineView.clickedRow)
            as? TerminalAgentSessionGroupOutlineItem
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
        guard let record = clickedOrSelectedRecord() else {
            return
        }
        onInsertResumeCommand?(record)
    }

    private func insertSelectedResumeCommand() {
        guard let record = selectedRecord() else {
            return
        }
        onInsertResumeCommand?(record)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let entries: [(L10nKey, Selector)] = [
            (.insertResumeCommand, #selector(insertResumeFromContextMenu(_:))),
            (.copyResumeCommand, #selector(copyResumeFromContextMenu(_:))),
            (.copySessionIdentifier, #selector(copySessionIdentifierFromContextMenu(_:))),
            (.copyTranscriptPath, #selector(copyTranscriptPathFromContextMenu(_:))),
            (.revealTranscriptInFinder, #selector(revealTranscriptFromContextMenu(_:))),
            (.openDirectoryInExplorer, #selector(openDirectoryFromContextMenu(_:))),
        ]
        let transcriptItem = NSMenuItem(
            title: AppLocalization.string(.openTranscript),
            action: #selector(openTranscriptFromContextMenu(_:)),
            keyEquivalent: ""
        )
        transcriptItem.target = self
        menu.addItem(transcriptItem)
        for (key, action) in entries {
            let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openTranscriptFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord() else {
            return
        }
        openTranscript(for: record)
    }

    @objc private func insertResumeFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord() else {
            return
        }
        onInsertResumeCommand?(record)
    }

    @objc private func copyResumeFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord() else {
            return
        }
        copyToPasteboard(AgentSessionResumeCommand.command(for: record))
    }

    @objc private func copySessionIdentifierFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord() else {
            return
        }
        copyToPasteboard(record.sessionID)
    }

    @objc private func copyTranscriptPathFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord() else {
            return
        }
        copyToPasteboard(record.filePath)
    }

    @objc private func revealTranscriptFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord(), !record.filePath.isEmpty else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.filePath)])
    }

    @objc private func openDirectoryFromContextMenu(_ sender: Any?) {
        guard let record = clickedOrSelectedRecord(), !record.cwd.isEmpty else {
            return
        }
        onOpenDirectoryInExplorer?(record)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Outline data source / delegate

extension TerminalAgentSessionPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let groupItem = item as? TerminalAgentSessionGroupOutlineItem else {
            return groupItems.count
        }
        return groupItem.sessionItems.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let groupItem = item as? TerminalAgentSessionGroupOutlineItem else {
            return groupItems[index]
        }
        return groupItem.sessionItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is TerminalAgentSessionGroupOutlineItem
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is TerminalAgentSessionOutlineItem
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard item is TerminalAgentSessionGroupOutlineItem else {
            return DesignTokens.Component.agentSessionRowHeightPX
        }
        return DesignTokens.Component.commandHistoryGroupRowHeightPX
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = TerminalCommandHistorySidebarRowView()
        rowView.chromeTheme = chromeTheme
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let groupItem = item as? TerminalAgentSessionGroupOutlineItem {
            return TerminalAgentSessionGroupCellView(
                display: groupItem.group.display,
                sessionCount: groupItem.group.sessionsNewestFirst.count,
                chromeTheme: chromeTheme
            )
        }
        guard let sessionItem = item as? TerminalAgentSessionOutlineItem else {
            return nil
        }
        return TerminalAgentSessionRowCellView(
            record: sessionItem.record,
            chromeTheme: chromeTheme,
            now: Date(),
            homeDirectory: homeDirectory
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
              searchPillView.stringValue.isEmpty,
              let groupItem = notification.userInfo?["NSObject"] as? TerminalAgentSessionGroupOutlineItem
        else {
            return
        }
        explicitExpansionByPath[groupItem.group.display.path] = isExpanded
    }
}

extension TerminalAgentSessionPanelView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let record = clickedOrSelectedRecord()
        let hasRecord = record != nil
        let hasDirectory = !(record?.cwd ?? "").isEmpty
        for item in menu.items {
            switch item.action {
            case #selector(openDirectoryFromContextMenu(_:)):
                item.isEnabled = hasDirectory
            default:
                item.isEnabled = hasRecord
            }
        }
    }
}
