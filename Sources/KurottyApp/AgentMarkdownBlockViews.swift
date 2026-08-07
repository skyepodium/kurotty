import AppKit

/// Column geometry for a rendered Markdown table.
///
/// Pure and separate from the view so the one property that matters — a table
/// never demands more width than the row gives it, at any width — is testable
/// without laying out AppKit.
enum AgentMarkdownTableLayout {
    /// Widths for one row of columns, scaled in proportion to fill `available`.
    ///
    /// The table fills the width it is given rather than keeping its natural
    /// widths. It has a header band behind its first row, and a band that runs
    /// the full width of a pane over columns that stop two thirds of the way
    /// across reads as a broken layout. Filling also makes trailing alignment
    /// mean something: a right-aligned column ends at the pane's edge.
    ///
    /// Shrinking is the interesting direction. Columns shrink in proportion and
    /// their text wraps; the floor stops a column collapsing into an unreadable
    /// stripe; and if honouring the floor would itself overflow, the row is
    /// split evenly — which sums to exactly `available` and so can never push
    /// the surrounding document sideways.
    static func columnWidths(
        natural: [CGFloat],
        available: CGFloat,
        minimum: CGFloat
    ) -> [CGFloat] {
        guard !natural.isEmpty else {
            return []
        }
        let total = natural.reduce(0, +)
        guard available > 0, total > 0 else {
            return natural
        }
        let scale = available / total
        let scaled = natural.map { $0 * scale }
        guard scale < 1 else {
            return scaled
        }
        let floored = scaled.map { max($0, minimum) }
        guard floored.reduce(0, +) > available else {
            return floored
        }
        return Array(repeating: available / CGFloat(natural.count), count: natural.count)
    }
}

/// A fenced code block: its language, and its code on lines that do not wrap.
///
/// The code scrolls horizontally inside this view. That containment is the
/// whole point — the transcript's own scroll view has no horizontal scroller,
/// so a long line that escaped this container would either be clipped away or
/// force the entire document sideways.
///
/// Height is arithmetic rather than measured: the paragraph style pins every
/// line to `agentTranscriptCodeLineHeightPX`, so the block is exactly its line
/// count tall. A non-wrapping block is the one case where that is knowable, and
/// knowing it keeps the row height stable while the tail is still being written.
@MainActor
final class AgentMarkdownCodeBlockView: NSView {
    private let scrollView = NSScrollView()
    /// A label, not an `NSTextView`. The text view brought a layout manager, a
    /// text container and a text storage per code block and measured five times
    /// slower on a transcript at the message cap, and it bought nothing: this
    /// text is never edited, never wraps, and a selectable label already copies.
    private let codeLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")

    /// Width the code actually needs. Larger than `bounds.width` is the normal
    /// case for real code and is what the horizontal scroller is for.
    private(set) var contentSize: CGSize = .zero

    init(language: String?, code: String, theme: DesignTokens.ChromeTheme) {
        super.init(frame: .zero)
        configure(language: language, code: code, theme: theme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(language: String?, code: String, theme: DesignTokens.ChromeTheme) {
        wantsLayer = true
        layer?.backgroundColor = theme.textPrimary
            .withAlphaComponent(DesignTokens.Component.agentTranscriptCodeBackgroundAlphaRATIO).cgColor
        layer?.cornerRadius = DesignTokens.Component.agentTranscriptCodeBlockCornerRadiusPX

        let lines = Self.lines(of: code)
        let attributed = Self.attributedCode(lines: lines, language: language, theme: theme)

        languageLabel.stringValue = (language?.isEmpty == false
            ? language!
            : AppLocalization.string(.transcriptCodeBlockUnlabeled)).localizedUppercase
        languageLabel.font = NSFont.systemFont(
            ofSize: DesignTokens.Component.agentTranscriptCodeLanguageFontSizePT,
            weight: .semibold
        )
        languageLabel.textColor = theme.textMuted
        languageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(languageLabel)

        codeLabel.attributedStringValue = attributed
        codeLabel.isSelectable = true
        codeLabel.maximumNumberOfLines = 0
        // Clipping rather than wrapping is what makes a long line stay on its
        // own line and reach for the horizontal scroller instead of reflowing.
        codeLabel.lineBreakMode = .byClipping
        codeLabel.cell?.usesSingleLineMode = false
        codeLabel.cell?.wraps = false
        codeLabel.translatesAutoresizingMaskIntoConstraints = true

        contentSize = CGSize(
            width: Self.widestLineWidth(lines),
            height: CGFloat(lines.count) * DesignTokens.Component.agentTranscriptCodeLineHeightPX
        )
        codeLabel.frame = CGRect(origin: .zero, size: contentSize)

        scrollView.documentView = codeLabel
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        // Overlay scrollers float over the code instead of reserving a strip,
        // which is what lets the arithmetic height above stay exact.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Without this the scroll view would inherit the document view's width
        // as a layout demand and widen the whole transcript row.
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(scrollView)

        let padX = DesignTokens.Component.agentTranscriptCodeBlockPaddingXPX
        let padY = DesignTokens.Component.agentTranscriptCodeBlockPaddingYPX
        NSLayoutConstraint.activate([
            languageLabel.topAnchor.constraint(equalTo: topAnchor, constant: padY),
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            languageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padX),
            scrollView.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: padY),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padY),
            scrollView.heightAnchor.constraint(equalToConstant: contentSize.height),
        ])
    }

    /// Code lines with the fence's trailing newline dropped. Foundation always
    /// terminates a code block, and an empty final line would add a blank row.
    static func lines(of code: String) -> [String] {
        var lines = code.components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// How far the code can scroll.
    ///
    /// Measured on the few longest lines rather than on the whole block. Laying
    /// out an entire fence just to learn its widest point cost more than
    /// everything else in the block put together, and in a monospaced face
    /// character count is very nearly width, so the longest candidates by
    /// length are the widest lines. Measuring several of them rather than one
    /// covers the case where a shorter line carries wider glyphs.
    static func widestLineWidth(_ lines: [String], candidates: Int = 4) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: AgentMarkdownFlowComposer.codeFont]
        return lines
            .sorted { $0.utf16.count > $1.utf16.count }
            .prefix(candidates)
            .reduce(0) { widest, line in
                max(widest, ceil((line as NSString).size(withAttributes: attributes).width))
            }
    }

    private static func attributedCode(
        lines: [String],
        language: String?,
        theme: DesignTokens.ChromeTheme
    ) -> NSAttributedString {
        let text = lines.joined(separator: "\n")
        let font = AgentMarkdownFlowComposer.codeFont
        let style = NSMutableParagraphStyle()
        let lineHeight = DesignTokens.Component.agentTranscriptCodeLineHeightPX
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byClipping
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: theme.textPrimary,
                .paragraphStyle: style,
            ]
        )
        // The editor's highlighter is a pure `(text, language) -> [token]`
        // function, so a rendered fence gets the same colours the code editor
        // gives the same file, with no new machinery.
        let syntax = CodeSyntaxLanguage(markdownLanguageHint: language ?? "")
        guard syntax != .plain else {
            return attributed
        }
        let palette = TerminalCodeEditorPalette.palette(for: theme)
        let full = NSRange(location: 0, length: attributed.length)
        for token in TerminalCodeSyntaxHighlighter.highlight(text: text, language: syntax) {
            guard NSIntersectionRange(token.range, full) == token.range else {
                continue
            }
            attributed.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: token.range)
        }
        return attributed
    }
}

/// A GFM table laid out as a real grid, honouring per-column alignment.
///
/// Manual layout rather than `NSGridView`: a grid view sizes its columns to
/// their cells' intrinsic content, so one wide cell would push the row past the
/// pane's width and drag the document sideways. Column widths here are a
/// function of the width the row was given, which is the only way a table can
/// live inside a pane that must never scroll horizontally.
@MainActor
final class AgentMarkdownTableView: NSView {
    private struct Cell {
        let label: NSTextField
        let naturalWidth: CGFloat

        /// Height this cell needs at `width`, asked of the cell that will draw
        /// it rather than of the attributed string it holds — the same source
        /// of truth `naturalWidth` uses, for the same reason.
        @MainActor
        func height(at width: CGFloat) -> CGFloat {
            guard let cell = label.cell else {
                return 0
            }
            return ceil(cell.cellSize(forBounds: CGRect(
                x: 0,
                y: 0,
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )).height)
        }
    }

    private let columns: [AgentMarkdownTable.Alignment]
    private let hasHeader: Bool
    private var rows: [[Cell]] = []
    private let headerFill = NSView()
    private let headerRule = NSView()
    /// Width the cached height belongs to. Height depends on width because
    /// cells wrap, so the height has to be recomputed — and re-published — every
    /// time the row is resized.
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0

    init(table: AgentMarkdownTable, theme: DesignTokens.ChromeTheme) {
        columns = table.columns
        hasHeader = table.header != nil
        super.init(frame: .zero)
        configure(table: table, theme: theme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(table: AgentMarkdownTable, theme: DesignTokens.ChromeTheme) {
        setAccessibilityLabel(AppLocalization.string(.transcriptTableAccessibility))

        headerFill.wantsLayer = true
        headerFill.layer?.backgroundColor = theme.textPrimary
            .withAlphaComponent(DesignTokens.Component.agentTranscriptTableHeaderBackgroundAlphaRATIO).cgColor
        headerFill.isHidden = !hasHeader
        addSubview(headerFill)

        headerRule.wantsLayer = true
        headerRule.layer?.backgroundColor = theme.hairline.cgColor
        headerRule.isHidden = !hasHeader
        addSubview(headerRule)

        if let header = table.header {
            rows.append(makeRow(header, theme: theme, isHeader: true))
        }
        for row in table.rows {
            rows.append(makeRow(row, theme: theme, isHeader: false))
        }
    }

    private func makeRow(
        _ cells: [[AgentMarkdownInline]],
        theme: DesignTokens.ChromeTheme,
        isHeader: Bool
    ) -> [Cell] {
        let font = isHeader
            ? NSFont.systemFont(ofSize: DesignTokens.Component.agentTranscriptBodyFontSizePT, weight: .semibold)
            : AgentMarkdownFlowComposer.bodyFont
        return cells.enumerated().map { index, inlines in
            let attributed = AgentMarkdownFlowComposer.attributed(
                inlines: inlines,
                baseFont: font,
                color: isHeader ? theme.textPrimary : theme.textSecondary,
                theme: theme
            )
            let label = NSTextField(labelWithAttributedString: attributed)
            label.isSelectable = true
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.alignment = Self.textAlignment(columns.indices.contains(index) ? columns[index] : .leading)
            label.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
            // The label's own unconstrained fitting width. Measuring the
            // attributed string instead was short by the inset `NSTextField`
            // keeps for its cell, which clipped the last glyph of every column
            // — a bug no frame assertion caught, because the frames agreed with
            // each other and were wrong together.
            return Cell(label: label, naturalWidth: ceil(label.fittingSize.width))
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let height = layoutRows(width: bounds.width)
        guard abs(height - measuredHeight) > 0.5 || abs(bounds.width - measuredWidth) > 0.5 else {
            return
        }
        measuredWidth = bounds.width
        measuredHeight = height
        invalidateIntrinsicContentSize()
    }

    /// Places every cell and reports the height the table needs at `width`.
    @discardableResult
    private func layoutRows(width: CGFloat) -> CGFloat {
        guard width > 0, !rows.isEmpty else {
            return 0
        }
        let padX = DesignTokens.Component.agentTranscriptTableCellPaddingXPX
        let padY = DesignTokens.Component.agentTranscriptTableCellPaddingYPX
        let widths = AgentMarkdownTableLayout.columnWidths(
            natural: naturalColumnWidths(),
            available: width,
            minimum: DesignTokens.Component.agentTranscriptTableMinimumColumnWidthPX
        )

        var y: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            var rowHeight: CGFloat = 0
            var frames: [CGRect] = []
            var x: CGFloat = 0
            for (columnIndex, cell) in row.enumerated() {
                let columnWidth = widths.indices.contains(columnIndex) ? widths[columnIndex] : 0
                let contentWidth = max(columnWidth - padX * 2, 1)
                let cellWidth = min(cell.naturalWidth, contentWidth)
                let cellHeight = cell.height(at: cellWidth)
                let offset = Self.alignmentOffset(
                    columns.indices.contains(columnIndex) ? columns[columnIndex] : .leading,
                    contentWidth: contentWidth,
                    cellWidth: cellWidth
                )
                frames.append(CGRect(x: x + padX + offset, y: 0, width: cellWidth, height: cellHeight))
                rowHeight = max(rowHeight, cellHeight)
                x += columnWidth
            }
            for (columnIndex, cell) in row.enumerated() {
                var frame = frames[columnIndex]
                frame.origin.y = y + padY
                cell.label.frame = frame
            }
            let fullRowHeight = rowHeight + padY * 2
            if rowIndex == 0, hasHeader {
                headerFill.frame = CGRect(x: 0, y: 0, width: width, height: fullRowHeight)
                headerRule.frame = CGRect(
                    x: 0,
                    y: fullRowHeight - DesignTokens.Component.hairlinePX,
                    width: width,
                    height: DesignTokens.Component.hairlinePX
                )
            }
            y += fullRowHeight
        }
        return y
    }

    private func naturalColumnWidths() -> [CGFloat] {
        let padX = DesignTokens.Component.agentTranscriptTableCellPaddingXPX
        var widths = [CGFloat](repeating: 0, count: columns.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.naturalWidth + padX * 2)
            }
        }
        return widths
    }

    private static func textAlignment(_ alignment: AgentMarkdownTable.Alignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }

    private static func alignmentOffset(
        _ alignment: AgentMarkdownTable.Alignment,
        contentWidth: CGFloat,
        cellWidth: CGFloat
    ) -> CGFloat {
        let slack = max(contentWidth - cellWidth, 0)
        switch alignment {
        case .leading: return 0
        case .center: return slack / 2
        case .trailing: return slack
        }
    }

    // MARK: - Testing

    /// Laid-out cell frames, row-major, header row first when there is one.
    /// Exposed because column alignment is only observable as geometry: reading
    /// the constraints proves nothing about where a right-aligned cell landed.
    var cellFramesForTesting: [[CGRect]] {
        rows.map { $0.map(\.label.frame) }
    }

    /// Column boxes as laid out, so a test can say where a cell *should* have
    /// landed rather than guessing at the geometry.
    var columnWidthsForTesting: [CGFloat] {
        AgentMarkdownTableLayout.columnWidths(
            natural: naturalColumnWidths(),
            available: bounds.width,
            minimum: DesignTokens.Component.agentTranscriptTableMinimumColumnWidthPX
        )
    }
}
