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
///
/// Message text is rendered as a Markdown document; tool input, tool output and
/// diffs are not. That line is deliberate. A message is prose an agent wrote for
/// a reader, so `##` should be a heading. A tool's input and output are verbatim
/// bytes, and reinterpreting a JSON payload or a shell transcript as Markdown
/// would silently rewrite the one thing the viewer exists to show truthfully.
@MainActor
final class AgentSessionTranscriptView: NSView {
    private enum Glyph {
        static let collapsed = "▸"
        static let expanded = "▾"
        static let removedPrefix = "- "
        static let addedPrefix = "+ "
    }

    /// Parsed message bodies, keyed by row identity.
    ///
    /// `viewFor` is called for every row the table paints and again whenever it
    /// measures a height, so parsing there without a cache would re-parse the
    /// visible window on every append while the tail is live. The cache is
    /// dropped wholesale rather than aged: it exists to cover a viewport, its
    /// entries cost nothing to rebuild, and an eviction policy would be more
    /// code than the thing it manages.
    private struct ParsedMessage {
        let text: String
        let blocks: [AgentMarkdownBlock]
    }

    private let controller: AgentSessionTranscriptController
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: AppLocalization.string(.transcriptEmpty))
    /// Shown only while the reader is holding back records older than its
    /// bounded tail window, so the view never implies it is showing everything.
    private let olderRecordsLabel = NSTextField(
        labelWithString: AppLocalization.string(.transcriptOlderRecordsHidden)
    )
    private var olderRecordsCollapsedConstraint: NSLayoutConstraint?
    private var rows: [AgentTranscriptRow] = []
    private var chromeTheme = DesignTokens.ChromeTheme.dark
    private var isFollowingTail = true
    private var parsedMessages: [String: ParsedMessage] = [:]
    /// Comfortably above any viewport, small enough that a 4,000-message
    /// transcript scrolled end to end cannot grow this without bound.
    private static let parsedMessageCacheLimit = 512

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
        olderRecordsLabel.textColor = theme.textMuted
        // Colours are baked into the composed attributed strings, so the rows
        // have to be rebuilt. The parsed block trees behind them carry no
        // colour and survive the change.
        tableView.reloadData()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = chromeTheme.windowBackground.cgColor
        // The viewer has no composer and no PTY handle; say so on hover.
        toolTip = AppLocalization.string(.transcriptReadOnly)

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
        emptyStateLabel.font = NSFont.systemFont(ofSize: DesignTokens.Component.agentTranscriptBodyFontSizePT)
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyStateLabel)

        olderRecordsLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Component.agentTranscriptHeaderFontSizePT
        )
        olderRecordsLabel.textColor = chromeTheme.textMuted
        olderRecordsLabel.isHidden = true
        olderRecordsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(olderRecordsLabel)
        // A hidden label still occupies its intrinsic height in Auto Layout, so
        // collapse it explicitly instead of leaving a blank strip.
        let collapsed = olderRecordsLabel.heightAnchor.constraint(equalToConstant: 0)
        collapsed.isActive = true
        olderRecordsCollapsedConstraint = collapsed

        NSLayoutConstraint.activate([
            olderRecordsLabel.topAnchor.constraint(equalTo: topAnchor),
            olderRecordsLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DesignTokens.Component.agentTranscriptRowInsetXPX
            ),
            olderRecordsLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -DesignTokens.Component.agentTranscriptRowInsetXPX
            ),
            scrollView.topAnchor.constraint(equalTo: olderRecordsLabel.bottomAnchor),
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
        olderRecordsLabel.isHidden = !snapshot.hasOlderRecords
        olderRecordsCollapsedConstraint?.isActive = !snapshot.hasOlderRecords
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
        let entries: [(L10nKey, Selector)] = [
            (.collapseAllToolRuns, #selector(collapseAllToolRuns(_:))),
            (.copyTranscriptPath, #selector(copyTranscriptPath(_:))),
            (.revealInFinder, #selector(revealInFinder(_:))),
        ]
        for (key, action) in entries {
            let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: "")
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
            return AppLocalization.string(.transcriptRoleUser)
        case .assistant:
            return AppLocalization.string(.transcriptRoleAgent)
        case .tool:
            return AppLocalization.string(.transcriptRoleTool)
        case .system:
            return AppLocalization.string(.transcriptRoleSystem)
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

    /// Coloured diff text. Static and pure for the same reason `diffLineText`
    /// is: the two colours *are* the diff's rendering contract, and reading a
    /// constraint proves nothing about them.
    static func diffAttributedString(
        _ diff: AgentTranscriptDiff,
        theme: DesignTokens.ChromeTheme
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(
            ofSize: DesignTokens.Component.agentTranscriptMonospacedFontSizePT,
            weight: .regular
        )
        for line in diff.lines {
            // Theme roles rather than the system palette: `systemRed` and
            // `systemGreen` here were the last raw `NSColor` references in the
            // app layer, and they read differently from every other red and
            // green in the chrome.
            let color = line.kind == .removed ? theme.error : theme.success
            text.append(NSAttributedString(
                string: diffLineText(line) + "\n",
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        return text
    }

    static func toolRunLabel(run: AgentTranscriptToolRun, isExpanded: Bool) -> String {
        let disclosure = isExpanded ? Glyph.expanded : Glyph.collapsed
        return "\(disclosure) \(run.summary)"
    }

    private func makeRowView(for row: AgentTranscriptRow) -> NSView {
        switch row {
        case let .turnHeader(_, role, timestamp):
            return makeHeaderView(role: role, timestamp: timestamp)
        case let .text(id, _, text):
            return makeMessageView(id: id, text: text)
        case let .toolRun(_, run, isExpanded):
            return makeLabelView(
                text: Self.toolRunLabel(run: run, isExpanded: isExpanded),
                font: NSFont.monospacedSystemFont(ofSize: DesignTokens.Component.agentTranscriptMonospacedFontSizePT, weight: .medium),
                color: chromeTheme.textSecondary,
                insetX: DesignTokens.Component.agentTranscriptRowInsetXPX,
                backgroundColor: nil
            )
        case let .toolDetail(_, detail):
            return makeLabelView(
                text: detail,
                font: NSFont.monospacedSystemFont(ofSize: DesignTokens.Component.agentTranscriptMonospacedFontSizePT, weight: .regular),
                color: chromeTheme.textMuted,
                insetX: DesignTokens.Component.agentTranscriptDetailInsetXPX,
                backgroundColor: chromeTheme.textPrimary
                    .withAlphaComponent(DesignTokens.Component.agentTranscriptDetailBackgroundAlphaRATIO)
            )
        case let .toolDiff(_, diff):
            return makeDiffView(diff)
        case let .toolOutput(_, output, isError):
            return makeLabelView(
                text: output,
                font: NSFont.monospacedSystemFont(ofSize: DesignTokens.Component.agentTranscriptMonospacedFontSizePT, weight: .regular),
                color: isError ? chromeTheme.activeIndicator : chromeTheme.textMuted,
                insetX: DesignTokens.Component.agentTranscriptDetailInsetXPX,
                backgroundColor: chromeTheme.textPrimary
                    .withAlphaComponent(DesignTokens.Component.agentTranscriptDetailBackgroundAlphaRATIO)
            )
        }
    }

    private func makeHeaderView(role: AgentTranscriptRole, timestamp: Date?) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: Self.roleLabel(for: role).localizedUppercase)
        label.font = NSFont.systemFont(ofSize: DesignTokens.Component.agentTranscriptHeaderFontSizePT, weight: .semibold)
        label.textColor = chromeTheme.textMuted
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DesignTokens.Component.agentTranscriptRowInsetXPX),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -DesignTokens.Component.agentTranscriptRowInsetXPX),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Component.agentTranscriptHeaderTopPaddingPX),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Component.agentTranscriptRowInsetYPX),
        ])
        return container
    }

    /// Message body as a rendered document. Parsing is lazy and cached so the
    /// cost lands on the rows the user can actually see rather than on all
    /// 4,000 the reader is holding.
    private func makeMessageView(id: String, text: String) -> NSView {
        AgentMarkdownDocumentView(
            blocks: blocks(id: id, text: text),
            theme: chromeTheme,
            insetX: DesignTokens.Component.agentTranscriptRowInsetXPX,
            insetY: DesignTokens.Component.agentTranscriptRowInsetYPX
        )
    }

    private func blocks(id: String, text: String) -> [AgentMarkdownBlock] {
        if let cached = parsedMessages[id], cached.text == text {
            return cached.blocks
        }
        if parsedMessages.count >= Self.parsedMessageCacheLimit {
            parsedMessages.removeAll(keepingCapacity: true)
        }
        let blocks = AgentTranscriptMarkdown.document(text)
        parsedMessages[id] = ParsedMessage(text: text, blocks: blocks)
        return blocks
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
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DesignTokens.Component.agentTranscriptRowInsetXPX),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Component.agentTranscriptRowInsetYPX),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Component.agentTranscriptRowInsetYPX),
        ])
        return container
    }

    private func makeDiffView(_ diff: AgentTranscriptDiff) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = chromeTheme.textPrimary
            .withAlphaComponent(DesignTokens.Component.agentTranscriptDiffBackgroundAlphaRATIO).cgColor

        let label = NSTextField(labelWithAttributedString: Self.diffAttributedString(diff, theme: chromeTheme))
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DesignTokens.Component.agentTranscriptDetailInsetXPX),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DesignTokens.Component.agentTranscriptRowInsetXPX),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Component.agentTranscriptRowInsetYPX),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Component.agentTranscriptRowInsetYPX),
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
