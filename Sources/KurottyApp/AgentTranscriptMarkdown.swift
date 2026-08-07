import Foundation

/// Inline styling carried by one span of text inside a block.
///
/// `intent` is Foundation's own option set rather than a re-declared enum: the
/// parser hands it over already populated, and re-encoding it would only add a
/// mapping table that can drift from the source of truth.
struct AgentMarkdownInline: Equatable, Sendable {
    var text: String
    var intent: InlinePresentationIntent
    /// Destination of a `[label](url)` span. Rendered as a styled link; the
    /// viewer never navigates on its own.
    var link: URL?

    init(text: String, intent: InlinePresentationIntent = [], link: URL? = nil) {
        self.text = text
        self.intent = intent
        self.link = link
    }

    var isEmphasized: Bool { intent.contains(.emphasized) }
    var isStronglyEmphasized: Bool { intent.contains(.stronglyEmphasized) }
    var isCode: Bool { intent.contains(.code) }
    var isStrikethrough: Bool { intent.contains(.strikethrough) }
    /// A soft break arrives as a lone space run; a hard break arrives as a
    /// newline run. Both are flow, not structure, so they stay inline.
    var isBreak: Bool { intent.contains(.softBreak) || intent.contains(.lineBreak) }
}

/// One list, ordered or not, with its items in document order.
struct AgentMarkdownList: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        /// 1-based position as the parser reported it, so `3.` in the source
        /// renders as `3.` rather than being renumbered.
        var ordinal: Int
        var blocks: [AgentMarkdownBlock]
    }

    var isOrdered: Bool
    var items: [Item]
}

/// A GFM table, already rectangular.
///
/// Every row is padded to `columns.count` at parse time. A transcript is
/// tail-followed, so a half-written row is normal input, and a renderer that
/// had to cope with ragged rows would push that check into layout code where
/// it is much harder to test.
struct AgentMarkdownTable: Equatable, Sendable {
    /// Per-column alignment. GFM's default (`|---|`, no colon) is reported by
    /// Foundation as `left`, so "unspecified" is not a state this can observe
    /// and is deliberately absent.
    enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    var columns: [Alignment]
    /// Absent when the source had no header row.
    var header: [[AgentMarkdownInline]]?
    var rows: [[[AgentMarkdownInline]]]
}

/// One block of a rendered transcript message.
indirect enum AgentMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [AgentMarkdownInline])
    case paragraph([AgentMarkdownInline])
    /// `language` is the fence's info string when it had one.
    case codeBlock(language: String?, code: String)
    case list(AgentMarkdownList)
    case blockQuote([AgentMarkdownBlock])
    case thematicBreak
    case table(AgentMarkdownTable)
}

/// Markdown source to a block tree, using Foundation's parser only.
///
/// Two properties matter more than fidelity, because the transcript is
/// tail-followed and therefore routinely parsed mid-write:
///
/// - **Nothing is swallowed.** A source that produces no blocks — a parse
///   failure, or markup Foundation drops entirely — degrades to one plain
///   paragraph carrying the original text. Showing raw `##` is a quality bug;
///   showing nothing is a correctness bug.
/// - **Nothing throws.** `returnPartiallyParsedIfPossible` plus a `catch` that
///   falls back to plain text means a half-written fence or a truncated table
///   row renders as far as it was written.
enum AgentTranscriptMarkdown {
    private static let parsingOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true,
        interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible
    )

    /// One run of the parsed string, with its block path flattened
    /// outermost-first. Foundation reports `components` innermost-first, which
    /// is the wrong end to recurse from.
    private struct Run {
        var inline: AgentMarkdownInline
        var path: [PresentationIntent.IntentType]
    }

    static func document(_ source: String) -> [AgentMarkdownBlock] {
        guard !source.isEmpty else {
            return []
        }
        guard let attributed = try? AttributedString(markdown: source, options: parsingOptions) else {
            return [plainFallback(source)]
        }

        var runs: [Run] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else {
                continue
            }
            runs.append(Run(
                inline: AgentMarkdownInline(
                    text: text,
                    intent: run.inlinePresentationIntent ?? [],
                    link: run.link
                ),
                // Reversed so index 0 is the outermost block and recursion can
                // walk the path by depth.
                path: (run.presentationIntent?.components ?? []).reversed()
            ))
        }

        let blocks = self.blocks(runs[...], depth: 0)
        guard blocks.isEmpty else {
            return blocks
        }
        // Whitespace-only sources legitimately produce nothing; anything else
        // producing nothing means the parser dropped real text.
        return source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [plainFallback(source)]
    }

    private static func plainFallback(_ source: String) -> AgentMarkdownBlock {
        .paragraph([AgentMarkdownInline(text: source)])
    }

    // MARK: - Tree assembly

    /// Splits a run slice into the blocks that begin at `depth`.
    ///
    /// Runs are already in document order and a block's runs are contiguous, so
    /// grouping by the identity at `depth` reconstructs the tree without any
    /// lookahead.
    private static func blocks(_ runs: ArraySlice<Run>, depth: Int) -> [AgentMarkdownBlock] {
        var blocks: [AgentMarkdownBlock] = []
        for group in groups(runs, depth: depth) {
            guard let component = group.component else {
                // Raw HTML blocks arrive with no presentation intent at all.
                // They are still the agent's text, so they render as a
                // paragraph rather than vanishing.
                blocks.append(.paragraph(inlines(group.runs)))
                continue
            }
            switch component.kind {
            case .paragraph:
                blocks.append(.paragraph(inlines(group.runs)))
            case let .header(level):
                blocks.append(.heading(level: level, inlines: inlines(group.runs)))
            case let .codeBlock(languageHint):
                blocks.append(.codeBlock(language: languageHint, code: text(group.runs)))
            case .blockQuote:
                blocks.append(.blockQuote(self.blocks(group.runs, depth: depth + 1)))
            case .unorderedList:
                blocks.append(.list(list(group.runs, depth: depth + 1, isOrdered: false)))
            case .orderedList:
                blocks.append(.list(list(group.runs, depth: depth + 1, isOrdered: true)))
            case .thematicBreak:
                blocks.append(.thematicBreak)
            case let .table(columns):
                blocks.append(.table(table(group.runs, depth: depth + 1, columns: columns.map(alignment))))
            default:
                // A list item, table row or cell reached without its container,
                // or a block kind added to Foundation after this was written.
                // Descend rather than drop: the text is still there.
                blocks.append(contentsOf: descend(group.runs, depth: depth + 1))
            }
        }
        return blocks
    }

    /// Continues past a component this code has no shape for, falling back to a
    /// paragraph once the path runs out.
    private static func descend(_ runs: ArraySlice<Run>, depth: Int) -> [AgentMarkdownBlock] {
        let nested = blocks(runs, depth: depth)
        return nested.isEmpty ? [.paragraph(inlines(runs))] : nested
    }

    private static func list(
        _ runs: ArraySlice<Run>,
        depth: Int,
        isOrdered: Bool
    ) -> AgentMarkdownList {
        var items: [AgentMarkdownList.Item] = []
        for group in groups(runs, depth: depth) {
            guard case let .listItem(ordinal)? = group.component?.kind else {
                // Content directly inside a list with no item wrapper: keep it
                // as an item so it is still numbered and indented.
                items.append(.init(ordinal: items.count + 1, blocks: descend(group.runs, depth: depth)))
                continue
            }
            items.append(.init(ordinal: ordinal, blocks: blocks(group.runs, depth: depth + 1)))
        }
        return AgentMarkdownList(isOrdered: isOrdered, items: items)
    }

    private static func table(
        _ runs: ArraySlice<Run>,
        depth: Int,
        columns: [AgentMarkdownTable.Alignment]
    ) -> AgentMarkdownTable {
        var header: [[AgentMarkdownInline]]?
        var rows: [[[AgentMarkdownInline]]] = []
        var columnCount = columns.count
        for group in groups(runs, depth: depth) {
            let cells = self.cells(group.runs, depth: depth + 1)
            columnCount = max(columnCount, cells.count)
            switch group.component?.kind {
            case .tableHeaderRow:
                header = cells
            default:
                rows.append(cells)
            }
        }
        // Pad every row to the widest row seen, so layout never indexes past
        // the end of a truncated mid-write row.
        var alignments = columns
        while alignments.count < columnCount {
            alignments.append(.leading)
        }
        return AgentMarkdownTable(
            columns: alignments,
            header: header.map { padded($0, to: columnCount) },
            rows: rows.map { padded($0, to: columnCount) }
        )
    }

    private static func cells(_ runs: ArraySlice<Run>, depth: Int) -> [[AgentMarkdownInline]] {
        var cells: [[AgentMarkdownInline]] = []
        for group in groups(runs, depth: depth) {
            guard case let .tableCell(columnIndex)? = group.component?.kind else {
                cells.append(inlines(group.runs))
                continue
            }
            // Address by the reported column so a cell the source skipped
            // leaves a gap rather than shifting its neighbours left.
            let index = Int(columnIndex)
            while cells.count <= index {
                cells.append([])
            }
            cells[index] = inlines(group.runs)
        }
        return cells
    }

    private static func padded(
        _ cells: [[AgentMarkdownInline]],
        to count: Int
    ) -> [[AgentMarkdownInline]] {
        guard cells.count < count else {
            return cells
        }
        return cells + Array(repeating: [], count: count - cells.count)
    }

    // MARK: - Run grouping

    private struct Group {
        /// `nil` when the path is exhausted at this depth.
        var component: PresentationIntent.IntentType?
        var runs: ArraySlice<Run>
    }

    private static func groups(_ runs: ArraySlice<Run>, depth: Int) -> [Group] {
        var groups: [Group] = []
        var index = runs.startIndex
        while index < runs.endIndex {
            let component = runs[index].path.count > depth ? runs[index].path[depth] : nil
            var end = runs.index(after: index)
            while end < runs.endIndex {
                let next = runs[end].path.count > depth ? runs[end].path[depth] : nil
                guard next?.identity == component?.identity else {
                    break
                }
                end = runs.index(after: end)
            }
            groups.append(Group(component: component, runs: runs[index..<end]))
            index = end
        }
        return groups
    }

    private static func inlines(_ runs: ArraySlice<Run>) -> [AgentMarkdownInline] {
        runs.map(\.inline)
    }

    private static func text(_ runs: ArraySlice<Run>) -> String {
        runs.map(\.inline.text).joined()
    }

    private static func alignment(
        _ column: PresentationIntent.TableColumn
    ) -> AgentMarkdownTable.Alignment {
        switch column.alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        @unknown default: return .leading
        }
    }
}
