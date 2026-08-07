import AppKit

/// One line of the hover popover.
///
/// Built from `TerminalCommandHistoryEntry` through the same
/// `TerminalCommandHistoryRowBuilder` the history sidebar uses, so a failed
/// command reads `"3m · 1"` here and in the panel rather than growing a second
/// spelling of the same fact.
struct TerminalPromptRailPopoverRow: Equatable {
    let spanID: TerminalCommandSpan.ID
    let commandText: String
    let detail: String
    let didFail: Bool
}

/// What the popover says for a hover at a given point on the rail.
///
/// Pure so the ordering, the entry cap, and the overflow count are testable
/// without a window.
enum TerminalPromptRailPopoverContent {
    /// Rows for the given spans, newest first, capped at `limit`.
    ///
    /// Newest first because the rail is read top-down as a timeline but a list
    /// of "what happened around here" is read the way every other command list
    /// in the app is read: most recent at the top.
    static func rows(
        forSpanIDs spanIDs: [TerminalCommandSpan.ID],
        markers: [TerminalPromptRailMarker],
        now: Date,
        limit: Int
    ) -> (rows: [TerminalPromptRailPopoverRow], overflowCOUNT: Int) {
        guard limit > 0 else { return ([], 0) }
        let wantedIDs = Set(spanIDs)
        let matched = markers
            .filter { wantedIDs.contains($0.spanID) }
            .sorted { $0.absoluteRowIndex > $1.absoluteRowIndex }
        let rows = matched.prefix(limit).map { marker in
            TerminalPromptRailPopoverRow(
                spanID: marker.spanID,
                commandText: marker.entry.commandText,
                detail: TerminalCommandHistoryRowBuilder.trailingDetailLabel(for: marker.entry, now: now),
                didFail: marker.didFail
            )
        }
        return (Array(rows), max(0, matched.count - rows.count))
    }
}

/// The rail itself: one mark per completed command, down the trailing edge.
///
/// It is a second control beside the scroll indicator rather than an extension
/// of it, and the two never overlap. They answer different questions — the
/// thumb answers "where am I, drag me", the rail answers "what happened where,
/// take me there" — but the bug this codebase already removed was two controls
/// answering the *same* question in the same 12pt strip. So the rail takes its
/// own 6pt strip flush to the edge and the indicator track is pushed inboard by
/// exactly that much; nothing is drawn twice and no point hit-tests to both.
@MainActor
final class TerminalPromptRailView: NSView {
    /// Fires with the absolute scrollback row a click asked for.
    var onSelectAbsoluteRow: ((Int) -> Void)?
    /// Fires with the spans under the pointer and the pointer's height in the
    /// rail's own coordinates, so the popover can be anchored to it. An empty
    /// array means the pointer left.
    var onHoverSpanIDs: (([TerminalCommandSpan.ID], CGFloat) -> Void)?

    var chromeTheme = DesignTokens.ChromeTheme.dark {
        didSet { needsDisplay = true }
    }

    private(set) var layoutModel: TerminalPromptRailLayout?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if let layer {
            ChromeMotion.disableImplicitAnimations(on: layer)
        }
        // VoiceOver cannot read a column of 3pt marks, so the strip names
        // itself; the popover's rows carry the per-command detail.
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(AppLocalization.string(.promptNavigatorAccessibility))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Arrow, not pointing hand: the pointing hand means "web link" on macOS
    /// and marks a control as not-native the moment it appears. The scroll
    /// indicator beside it follows the same rule, and two neighbouring strips
    /// with different cursors would read as two unrelated features.
    var railCursor: NSCursor { .arrow }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: railCursor)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func apply(_ layout: TerminalPromptRailLayout?) {
        layoutModel = layout
        isHidden = layout == nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let nextTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        reportHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        reportHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverSpanIDs?([], 0)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cluster = layoutModel?.cluster(atY: point.y) else { return }
        onSelectAbsoluteRow?(cluster.anchorAbsoluteRowIndex)
    }

    // MARK: - Test seams

    func reportHoverForTesting(atY y: CGFloat) {
        reportHover(atLocalY: y)
    }

    func selectForTesting(atY y: CGFloat) {
        guard let cluster = layoutModel?.cluster(atY: y) else { return }
        onSelectAbsoluteRow?(cluster.anchorAbsoluteRowIndex)
    }

    func markColorForTesting(_ cluster: TerminalPromptRailCluster) -> NSColor {
        markColor(for: cluster)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutModel else { return }
        for cluster in layoutModel.clusters {
            markColor(for: cluster).setFill()
            let path = NSBezierPath(
                roundedRect: cluster.frame,
                xRadius: cluster.frame.height / 2,
                yRadius: cluster.frame.height / 2
            )
            path.fill()
        }
    }

    /// Status encoding. A slot holding any failure is drawn in the theme's
    /// `error` at full strength no matter how crowded the rail is, because a
    /// failure that fades out with density is a failure the rail hid.
    private func markColor(for cluster: TerminalPromptRailCluster) -> NSColor {
        guard let layoutModel else { return chromeTheme.success }
        if cluster.hasFailure {
            return chromeTheme.error
        }
        guard layoutModel.mode == .heat else {
            return chromeTheme.success.withAlphaComponent(DesignTokens.Color.promptRailSuccessAlphaRATIO)
        }
        let minimumAlpha = DesignTokens.Color.promptRailHeatMinAlphaRATIO
        let maximumAlpha = DesignTokens.Color.promptRailHeatMaxAlphaRATIO
        let alpha = minimumAlpha + (maximumAlpha - minimumAlpha) * cluster.densityRATIO
        return chromeTheme.success.withAlphaComponent(alpha)
    }

    // MARK: - Pointer

    private func reportHover(atWindowPoint windowPoint: NSPoint) {
        reportHover(atLocalY: convert(windowPoint, from: nil).y)
    }

    private func reportHover(atLocalY y: CGFloat) {
        guard let layoutModel else {
            onHoverSpanIDs?([], y)
            return
        }
        let clusters = layoutModel.nearestClusters(
            toY: y,
            limit: DesignTokens.Component.terminalPromptRailPopoverClusterLIMIT
        )
        onHoverSpanIDs?(clusters.flatMap(\.spanIDs), y)
    }
}

/// The hover list: time, command text, and the exit code where it failed.
///
/// A plain view rather than an `NSPopover` because it has to appear and move
/// while the pointer slides along a 6pt strip; a popover's arrow and animation
/// would make that feel like a series of separate windows opening.
@MainActor
final class TerminalPromptRailPopoverView: NSView {
    private let stackView = NSStackView()
    private var rowViews: [TerminalPromptRailPopoverRowView] = []
    private let overflowLabel = NSTextField(labelWithString: "")

    var chromeTheme = DesignTokens.ChromeTheme.dark {
        didSet { applyTheme() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        if let layer {
            ChromeMotion.disableImplicitAnimations(on: layer)
            layer.cornerRadius = DesignTokens.Radius.mdPX
            layer.borderWidth = 1
        }
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        let inset = DesignTokens.Component.terminalPromptRailPopoverInsetPX
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset),
        ])
        DesignTokens.Typography.rowSecondary.apply(to: overflowLabel, color: DesignTokens.ChromeTheme.dark.textTertiary)
        applyTheme()
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Rows currently on screen, in display order. The popover's whole job is
    /// what it says, so what it says is readable back.
    private(set) var displayedRows: [TerminalPromptRailPopoverRow] = []

    func present(rows: [TerminalPromptRailPopoverRow], overflowCOUNT: Int) {
        guard !rows.isEmpty else {
            isHidden = true
            displayedRows = []
            return
        }
        displayedRows = rows
        synchronizeRowViews(count: rows.count)
        for (index, row) in rows.enumerated() {
            rowViews[index].apply(row, chromeTheme: chromeTheme)
        }
        overflowLabel.stringValue = overflowCOUNT > 0
            ? AppLocalization.format(.promptNavigatorMoreCommands, overflowCOUNT)
            : ""
        overflowLabel.isHidden = overflowCOUNT <= 0
        isHidden = false
        setFrameSize(fittingSize(rowCount: rows.count, showsOverflow: overflowCOUNT > 0))
        layoutSubtreeIfNeeded()
    }

    func dismiss() {
        isHidden = true
        displayedRows = []
    }

    func fittingSize(rowCount: Int, showsOverflow: Bool) -> NSSize {
        let rowHeight = DesignTokens.Component.terminalPromptRailPopoverRowHeightPX
        let inset = DesignTokens.Component.terminalPromptRailPopoverInsetPX
        let visibleRowCount = CGFloat(rowCount) + (showsOverflow ? 1 : 0)
        return NSSize(
            width: DesignTokens.Component.terminalPromptRailPopoverWidthPX,
            height: rowHeight * visibleRowCount + inset * 2
        )
    }

    private func synchronizeRowViews(count: Int) {
        while rowViews.count < count {
            let rowView = TerminalPromptRailPopoverRowView()
            rowViews.append(rowView)
            stackView.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            rowView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.terminalPromptRailPopoverRowHeightPX
            ).isActive = true
        }
        for (index, rowView) in rowViews.enumerated() {
            rowView.isHidden = index >= count
        }
        if overflowLabel.superview == nil {
            stackView.addArrangedSubview(overflowLabel)
        }
    }

    private func applyTheme() {
        layer?.backgroundColor = chromeTheme.surfaceRaised.cgColor
        layer?.borderColor = chromeTheme.hairline.cgColor
        overflowLabel.textColor = chromeTheme.textTertiary
    }
}

/// One popover line: command text on the left, `"3m · 1"` on the right.
@MainActor
final class TerminalPromptRailPopoverRowView: NSView {
    private let commandLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(commandLabel)
        addSubview(detailLabel)
        let gap = DesignTokens.Component.terminalPromptRailPopoverGapPX
        NSLayoutConstraint.activate([
            commandLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            commandLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: commandLabel.trailingAnchor, constant: gap),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var commandTextForTesting: String { commandLabel.stringValue }
    var detailTextForTesting: String { detailLabel.stringValue }
    var commandLabelForTesting: NSTextField { commandLabel }
    var detailLabelForTesting: NSTextField { detailLabel }

    func apply(_ row: TerminalPromptRailPopoverRow, chromeTheme: DesignTokens.ChromeTheme) {
        commandLabel.stringValue = row.commandText
        detailLabel.stringValue = row.detail
        DesignTokens.Typography.monoBody.apply(to: commandLabel, color: chromeTheme.textPrimary)
        // The detail carries the exit code, so a failure colours the whole
        // trailing label rather than growing a third element in a 20pt row.
        DesignTokens.Typography.rowSecondary.apply(
            to: detailLabel,
            color: row.didFail ? chromeTheme.error : chromeTheme.textTertiary
        )
    }
}
