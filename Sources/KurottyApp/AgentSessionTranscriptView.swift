import AppKit

/// Read-only transcript viewer.
///
/// Safety contract: there is no composer, no send button, and no PTY handle
/// anywhere in this view or its controller. It renders records an agent already
/// wrote to disk and nothing else.
///
/// Layout follows the flat-inline-row model rather than boxed tool cards: a
/// tool run is one `▸ Edit  src/foo.swift` line that expands in place into its
/// input, a synthesized diff, and its output, so a turn with many tool calls
/// stays scannable.
@MainActor
final class AgentSessionTranscriptView: NSView {
    /// Strings that belong in `AppLocalization` once this wave's file ownership
    /// split ends. Listed in the handoff report for migration.
    private enum Copy {
        static let emptyState = "This transcript has no readable records yet."
        static let readOnlyBadge = "Read-only"
        static let olderRecordsNotice = "Older records are not shown."
        static let userRole = "You"
        static let assistantRole = "Agent"
        static let toolRole = "Tool"
        static let systemRole = "System"
        static let collapseAll = "Collapse All Tool Runs"
        static let copyTranscriptPath = "Copy Transcript Path"
        static let revealInFinder = "Reveal in Finder"
    }

    private enum Glyph {
        static let collapsed = "▸"
        static let expanded = "▾"
        static let removedPrefix = "- "
        static let addedPrefix = "+ "
    }

    private enum Metric {
        static let rowInsetXPX: CGFloat = 14
        static let rowInsetYPX: CGFloat = 4
        static let detailInsetXPX: CGFloat = 30
        static let headerTopPaddingPX: CGFloat = 10
        static let bodyFontSizePT: CGFloat = 12
        static let headerFontSizePT: CGFloat = 10
        static let monospacedFontSizePT: CGFloat = 11
        static let detailBackgroundAlphaRATIO: CGFloat = 0.06
        static let diffBackgroundAlphaRATIO: CGFloat = 0.10
    }

    private let controller: AgentSessionTranscriptController
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: Copy.emptyState)
    private var rows: [AgentTranscriptRow] = []
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var isFollowingTail = true

    init(controller: AgentSessionTranscriptController) {
        self.controller = controller
        super.init(frame: .zero)
        configure()
        controller.onChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        controller.start()
        apply(controller.snapshot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            controller.stop()
        }
    }

    var record: AgentSessionRecord {
        controller.record
    }

    var visibleRowsForTesting: [AgentTranscriptRow] {
        rows
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        layer?.backgroundColor = theme.windowBackground.cgColor
        emptyStateLabel.textColor = theme.textMuted
        tableView.reloadData()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = chromeTheme.windowBackground.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = true
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.menu = makeContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = chromeTheme.textMuted
        emptyStateLabel.font = NSFont.systemFont(ofSize: Metric.bodyFontSizePT)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyStateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
    }

    /// Applies a batched snapshot. Keeps the view pinned to the newest record
    /// only while the user is already at the bottom, so scrolling back through
    /// history is not yanked away by an append.
    private func apply(_ snapshot: AgentSessionTranscriptController.Snapshot) {
        isFollowingTail = isScrolledToBottom
        rows = snapshot.rows
        emptyStateLabel.isHidden = !rows.isEmpty
        tableView.reloadData()
        guard isFollowingTail, !rows.isEmpty else {
            return
        }
        tableView.scrollRowToVisible(rows.count - 1)
    }

    private var isScrolledToBottom: Bool {
        let documentHeight = tableView.bounds.height
        let visible = scrollView.contentView.documentVisibleRect
        guard documentHeight > visible.height else {
            return true
        }
        return visible.maxY >= documentHeight - visible.height * 0.1
    }

    @objc private func rowClicked(_ sender: Any?) {
        let clicked = tableView.clickedRow
        guard rows.indices.contains(clicked),
              case let .toolRun(id, _, _) = rows[clicked]
        else {
            return
        }
        controller.toggleToolRun(id: id)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, Selector)] = [
            (Copy.collapseAll, #selector(collapseAllToolRuns(_:))),
            (Copy.copyTranscriptPath, #selector(copyTranscriptPath(_:))),
            (Copy.revealInFinder, #selector(revealInFinder(_:))),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func collapseAllToolRuns(_ sender: Any?) {
        controller.collapseAllToolRuns()
    }

    @objc private func copyTranscriptPath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.filePath, forType: .string)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard !record.filePath.isEmpty else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.filePath)])
    }

    // MARK: - Row views

    static func roleLabel(for role: AgentTranscriptRole) -> String {
        switch role {
        case .user:
            return Copy.userRole
        case .assistant:
            return Copy.assistantRole
        case .tool:
            return Copy.toolRole
        case .system:
            return Copy.systemRole
        }
    }

    /// Prefixed diff text. Kept static and pure so the rendering contract is
    /// testable without instantiating AppKit views.
    static func diffLineText(_ line: AgentTranscriptDiff.Line) -> String {
        switch line.kind {
        case .removed:
            return Glyph.removedPrefix + line.text
        case .added:
            return Glyph.addedPrefix + line.text
        }
    }

    static func toolRunLabel(run: AgentTranscriptToolRun, isExpanded: Bool) -> String {
        let disclosure = isExpanded ? Glyph.expanded : Glyph.collapsed
        return "\(disclosure) \(run.summary)"
    }

    private func makeRowView(for row: AgentTranscriptRow) -> NSView {
        switch row {
        case let .turnHeader(_, role, timestamp):
            return makeHeaderView(role: role, timestamp: timestamp)
        case let .text(_, _, text):
            return makeLabelView(
                text: text,
                font: NSFont.systemFont(ofSize: Metric.bodyFontSizePT),
                color: chromeTheme.textPrimary,
                insetX: Metric.rowInsetXPX,
                backgroundColor: nil
            )
        case let .toolRun(_, run, isExpanded):
            return makeLabelView(
                text: Self.toolRunLabel(run: run, isExpanded: isExpanded),
                font: NSFont.monospacedSystemFont(ofSize: Metric.monospacedFontSizePT, weight: .medium),
                color: chromeTheme.textSecondary,
                insetX: Metric.rowInsetXPX,
                backgroundColor: nil
            )
        case let .toolDetail(_, detail):
            return makeLabelView(
                text: detail,
                font: NSFont.monospacedSystemFont(ofSize: Metric.monospacedFontSizePT, weight: .regular),
                color: chromeTheme.textMuted,
                insetX: Metric.detailInsetXPX,
                backgroundColor: chromeTheme.textPrimary
                    .withAlphaComponent(Metric.detailBackgroundAlphaRATIO)
            )
        case let .toolDiff(_, diff):
            return makeDiffView(diff)
        case let .toolOutput(_, output, isError):
            return makeLabelView(
                text: output,
                font: NSFont.monospacedSystemFont(ofSize: Metric.monospacedFontSizePT, weight: .regular),
                color: isError ? chromeTheme.activeIndicator : chromeTheme.textMuted,
                insetX: Metric.detailInsetXPX,
                backgroundColor: chromeTheme.textPrimary
                    .withAlphaComponent(Metric.detailBackgroundAlphaRATIO)
            )
        }
    }

    private func makeHeaderView(role: AgentTranscriptRole, timestamp: Date?) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: Self.roleLabel(for: role).localizedUppercase)
        label.font = NSFont.systemFont(ofSize: Metric.headerFontSizePT, weight: .semibold)
        label.textColor = chromeTheme.textMuted
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metric.rowInsetXPX),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Metric.rowInsetXPX),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: Metric.headerTopPaddingPX),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metric.rowInsetYPX),
        ])
        return container
    }

    private func makeLabelView(
        text: String,
        font: NSFont,
        color: NSColor,
        insetX: CGFloat,
        backgroundColor: NSColor?
    ) -> NSView {
        let container = NSView()
        if let backgroundColor {
            container.wantsLayer = true
            container.layer?.backgroundColor = backgroundColor.cgColor
        }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insetX),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metric.rowInsetXPX),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: Metric.rowInsetYPX),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metric.rowInsetYPX),
        ])
        return container
    }

    private func makeDiffView(_ diff: AgentTranscriptDiff) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(Metric.diffBackgroundAlphaRATIO).cgColor

        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: Metric.monospacedFontSizePT, weight: .regular)
        for line in diff.lines {
            let color = line.kind == .removed ? NSColor.systemRed : NSColor.systemGreen
            text.append(NSAttributedString(
                string: Self.diffLineText(line) + "\n",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Metric.detailInsetXPX),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Metric.rowInsetXPX),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: Metric.rowInsetYPX),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Metric.rowInsetYPX),
        ])
        return container
    }
}

extension AgentSessionTranscriptView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else {
            return nil
        }
        return makeRowView(for: rows[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}
