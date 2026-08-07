import AppKit

/// One unit of layout inside a rendered message.
///
/// The split between `flow` and everything else is the central rendering
/// decision, so it is stated here rather than implied by the view code.
///
/// Headings, paragraphs and simple lists are *paragraph styling*: they differ
/// from one another by font, indent, leading and tab stops, all of which
/// `NSParagraphStyle` expresses. Composing a run of them into one
/// `NSAttributedString` costs exactly one text field — the same one view the
/// transcript already spent on a plain string — so the overwhelmingly common
/// message, prose with some bold in it, gets richer at no view cost at all.
///
/// Code blocks and tables are not styling. A code block must not reflow and
/// therefore needs its own clipping, horizontally scrollable container; a table
/// needs column geometry that no paragraph style can express (`NSTextTable`
/// exists, but its column widths are fixed at build time and cannot respond to
/// the row's width). Those two, plus rules and quoted or list-nested
/// containers, break the flow run and become views.
///
/// The cost of a message is therefore proportional to how many code blocks and
/// tables it contains, not to how many blocks it contains.
enum AgentMarkdownSegment: Equatable {
    /// Blocks that compose into a single attributed string.
    case flow([AgentMarkdownBlock])
    case code(language: String?, code: String)
    case table(AgentMarkdownTable)
    case rule
    /// A recursive document behind an indent.
    case nested(Container, [AgentMarkdownBlock])

    enum Container: Equatable {
        case quote
        /// A list item whose content is not pure flow — one carrying a code
        /// block, say. Rendered as a marker beside a nested document instead of
        /// as a tab-stopped line.
        case listItem(marker: String)
    }
}

enum AgentMarkdownSegmentPlanner {
    /// Groups blocks into the fewest segments that can each be drawn by one
    /// view, coalescing adjacent flow blocks.
    static func segments(for blocks: [AgentMarkdownBlock]) -> [AgentMarkdownSegment] {
        var segments: [AgentMarkdownSegment] = []
        var flow: [AgentMarkdownBlock] = []

        func flushFlow() {
            guard !flow.isEmpty else {
                return
            }
            segments.append(.flow(flow))
            flow = []
        }

        for block in blocks {
            switch block {
            case .heading, .paragraph:
                flow.append(block)
            case let .list(list) where isFlow(list):
                flow.append(block)
            case let .list(list):
                // One item carrying a code block does not disqualify the rest,
                // but the list has to become views to hold it, so all of its
                // items do.
                flushFlow()
                for item in list.items {
                    segments.append(.nested(
                        .listItem(marker: marker(for: item, isOrdered: list.isOrdered)),
                        item.blocks
                    ))
                }
            case let .codeBlock(language, code):
                flushFlow()
                segments.append(.code(language: language, code: code))
            case let .table(table):
                flushFlow()
                segments.append(.table(table))
            case let .blockQuote(inner):
                flushFlow()
                segments.append(.nested(.quote, inner))
            case .thematicBreak:
                flushFlow()
                segments.append(.rule)
            }
        }
        flushFlow()
        return segments
    }

    /// Bullet or ordinal shown beside a list item.
    static func marker(for item: AgentMarkdownList.Item, isOrdered: Bool) -> String {
        isOrdered ? "\(item.ordinal)." : "•"
    }

    private static func isFlow(_ list: AgentMarkdownList) -> Bool {
        list.items.allSatisfy { $0.blocks.allSatisfy(isFlow) }
    }

    private static func isFlow(_ block: AgentMarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph:
            return true
        case let .list(list):
            return isFlow(list)
        case .codeBlock, .table, .blockQuote, .thematicBreak:
            return false
        }
    }
}

/// Composes a run of flow blocks into one attributed string.
///
/// Every font, colour and metric here comes from `DesignTokens` or the active
/// `ChromeTheme`, so a rendered message re-themes with the rest of the chrome.
@MainActor
enum AgentMarkdownFlowComposer {
    static func attributedString(
        blocks: [AgentMarkdownBlock],
        theme: DesignTokens.ChromeTheme
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append(blocks: blocks, to: output, theme: theme, indent: 0, isFirst: true)
        return output
    }

    private static func append(
        blocks: [AgentMarkdownBlock],
        to output: NSMutableAttributedString,
        theme: DesignTokens.ChromeTheme,
        indent: CGFloat,
        isFirst: Bool
    ) {
        for (index, block) in blocks.enumerated() {
            let isFirstBlock = isFirst && index == 0
            switch block {
            case let .heading(level, inlines):
                appendLine(
                    inlines: inlines,
                    to: output,
                    theme: theme,
                    font: headingFont(level: level),
                    color: theme.textPrimary,
                    style: headingParagraphStyle(indent: indent, isFirst: isFirstBlock)
                )
            case let .paragraph(inlines):
                appendLine(
                    inlines: inlines,
                    to: output,
                    theme: theme,
                    font: bodyFont,
                    color: theme.textPrimary,
                    style: paragraphStyle(indent: indent)
                )
            case let .list(list):
                appendList(list, to: output, theme: theme, indent: indent)
            case .codeBlock, .table, .blockQuote, .thematicBreak:
                // The planner never routes these here; if one arrives anyway it
                // is better to draw its text than to drop the message.
                appendLine(
                    inlines: [AgentMarkdownInline(text: fallbackText(block))],
                    to: output,
                    theme: theme,
                    font: codeFont,
                    color: theme.textSecondary,
                    style: paragraphStyle(indent: indent)
                )
            }
        }
    }

    private static func appendList(
        _ list: AgentMarkdownList,
        to output: NSMutableAttributedString,
        theme: DesignTokens.ChromeTheme,
        indent: CGFloat
    ) {
        let markerColumn = DesignTokens.Component.agentTranscriptListMarkerColumnPX
        for item in list.items {
            let marker = AgentMarkdownSegmentPlanner.marker(for: item, isOrdered: list.isOrdered)
            for (index, block) in item.blocks.enumerated() {
                switch block {
                case let .paragraph(inlines), let .heading(_, inlines):
                    // Only the item's first paragraph wears the marker; a
                    // continuation paragraph lines up under the text instead.
                    let style = listParagraphStyle(indent: indent, markerColumn: markerColumn)
                    if index == 0 {
                        appendLine(
                            inlines: inlines,
                            to: output,
                            theme: theme,
                            font: bodyFont,
                            color: theme.textPrimary,
                            style: style,
                            prefix: marker + "\t"
                        )
                    } else {
                        appendLine(
                            inlines: inlines,
                            to: output,
                            theme: theme,
                            font: bodyFont,
                            color: theme.textPrimary,
                            style: continuationParagraphStyle(indent: indent, markerColumn: markerColumn)
                        )
                    }
                case let .list(nested):
                    appendList(
                        nested,
                        to: output,
                        theme: theme,
                        indent: indent + DesignTokens.Component.agentTranscriptListIndentPX
                    )
                case .codeBlock, .table, .blockQuote, .thematicBreak:
                    append(
                        blocks: [block],
                        to: output,
                        theme: theme,
                        indent: indent + DesignTokens.Component.agentTranscriptListIndentPX,
                        isFirst: false
                    )
                }
            }
        }
    }

    private static func appendLine(
        inlines: [AgentMarkdownInline],
        to output: NSMutableAttributedString,
        theme: DesignTokens.ChromeTheme,
        font: NSFont,
        color: NSColor,
        style: NSParagraphStyle,
        prefix: String? = nil
    ) {
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n"))
        }
        let start = output.length
        if let prefix {
            output.append(NSAttributedString(
                string: prefix,
                attributes: [.font: font, .foregroundColor: theme.textSecondary]
            ))
        }
        output.append(attributed(inlines: inlines, baseFont: font, color: color, theme: theme))
        output.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: start, length: output.length - start)
        )
    }

    /// Inline spans of one block, with emphasis, code, strikethrough and links.
    static func attributed(
        inlines: [AgentMarkdownInline],
        baseFont: NSFont,
        color: NSColor,
        theme: DesignTokens.ChromeTheme
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for inline in inlines {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if inline.isCode {
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize * inlineCodeSizeRatio,
                    weight: .regular
                )
                attributes[.backgroundColor] = theme.textPrimary.withAlphaComponent(
                    DesignTokens.Component.agentTranscriptInlineCodeBackgroundAlphaRATIO
                )
            } else {
                attributes[.font] = emphasized(baseFont, inline: inline)
            }
            if inline.isStrikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = inline.link {
                attributes[.link] = link
                attributes[.foregroundColor] = theme.accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: inline.text, attributes: attributes))
        }
        return output
    }

    private static func emphasized(_ font: NSFont, inline: AgentMarkdownInline) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if inline.isStronglyEmphasized {
            traits.insert(.bold)
        }
        if inline.isEmphasized {
            traits.insert(.italic)
        }
        guard !traits.isEmpty else {
            return font
        }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Fonts

    /// Inline code sits slightly below the prose around it: a monospaced face
    /// at the same point size reads as larger than the proportional one beside
    /// it and makes the line look broken.
    private static let inlineCodeSizeRatio: CGFloat = 0.92

    static var bodyFont: NSFont {
        NSFont.systemFont(ofSize: DesignTokens.Component.agentTranscriptBodyFontSizePT)
    }

    static var codeFont: NSFont {
        NSFont.monospacedSystemFont(
            ofSize: DesignTokens.Component.agentTranscriptMonospacedFontSizePT,
            weight: .regular
        )
    }

    static func headingFont(level: Int) -> NSFont {
        let sizes = DesignTokens.Component.agentTranscriptHeadingFontSizesPT
        let index = min(max(level, 1), sizes.count) - 1
        return NSFont.systemFont(ofSize: sizes[index], weight: .semibold)
    }

    // MARK: - Paragraph styles

    private static func paragraphStyle(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = DesignTokens.Component.agentTranscriptParagraphSpacingPX
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    private static func headingParagraphStyle(indent: CGFloat, isFirst: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = DesignTokens.Component.agentTranscriptParagraphSpacingPX
        // A message that opens with a heading needs no lead-in air; one that
        // reaches a heading mid-message does.
        style.paragraphSpacingBefore = isFirst
            ? 0
            : DesignTokens.Component.agentTranscriptHeadingSpacingBeforePX
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    private static func listParagraphStyle(indent: CGFloat, markerColumn: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // Tighter than between paragraphs: list items are one thought.
        style.paragraphSpacing = DesignTokens.Component.agentTranscriptParagraphSpacingPX / 2
        style.firstLineHeadIndent = indent
        // Wrapped lines and the tab stop land on the same column, so a two-line
        // item hangs under its own text rather than under its bullet.
        style.headIndent = indent + markerColumn
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerColumn)]
        style.defaultTabInterval = markerColumn
        return style
    }

    private static func continuationParagraphStyle(
        indent: CGFloat,
        markerColumn: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = DesignTokens.Component.agentTranscriptParagraphSpacingPX / 2
        style.firstLineHeadIndent = indent + markerColumn
        style.headIndent = indent + markerColumn
        return style
    }

    /// Visible text of a block the composer has no styling for.
    ///
    /// The planner never routes one here, but "never" is a claim about two
    /// files agreeing. If they ever stop agreeing, the failure has to be an ugly
    /// paragraph rather than a message that silently loses a table.
    private static func fallbackText(_ block: AgentMarkdownBlock) -> String {
        switch block {
        case let .heading(_, inlines), let .paragraph(inlines):
            return inlines.map(\.text).joined()
        case let .codeBlock(_, code):
            return code
        case let .list(list):
            return list.items.map { fallbackText(blocks: $0.blocks) }.joined(separator: "\n")
        case let .blockQuote(inner):
            return fallbackText(blocks: inner)
        case .thematicBreak:
            return ""
        case let .table(table):
            let rows = (table.header.map { [$0] } ?? []) + table.rows
            return rows
                .map { row in row.map { $0.map(\.text).joined() }.joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }

    private static func fallbackText(blocks: [AgentMarkdownBlock]) -> String {
        blocks.map(fallbackText).joined(separator: "\n")
    }
}
