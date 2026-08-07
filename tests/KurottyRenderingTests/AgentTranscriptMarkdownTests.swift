import AppKit
import XCTest
@testable import KurottyApp

/// The block model: what each Markdown construct parses to.
///
/// These assert the tree, not the pixels, because everything downstream —
/// segment planning, paragraph styling, table geometry — is a function of it.
final class AgentTranscriptMarkdownTests: XCTestCase {
    private func blocks(_ source: String) -> [AgentMarkdownBlock] {
        AgentTranscriptMarkdown.document(source)
    }

    /// Concatenated visible text of a block tree, used to assert that a parse
    /// lost nothing.
    private func plainText(_ blocks: [AgentMarkdownBlock]) -> String {
        blocks.map { block in
            switch block {
            case let .heading(_, inlines), let .paragraph(inlines):
                return inlines.map(\.text).joined()
            case let .codeBlock(_, code):
                return code
            case let .list(list):
                return list.items.map { plainText($0.blocks) }.joined(separator: "\n")
            case let .blockQuote(inner):
                return plainText(inner)
            case .thematicBreak:
                return ""
            case let .table(table):
                let cells = (table.header.map { [$0] } ?? []) + table.rows
                return cells.map { row in row.map { $0.map(\.text).joined() }.joined(separator: " ") }
                    .joined(separator: "\n")
            }
        }
        .joined(separator: "\n")
    }

    func testHeadingCarriesItsLevel() throws {
        guard case let .heading(level, inlines) = try XCTUnwrap(blocks("## Plan").first) else {
            return XCTFail("expected a heading")
        }

        XCTAssertEqual(level, 2)
        XCTAssertEqual(inlines.map(\.text), ["Plan"])
    }

    func testSixHeadingLevelsAreAllDistinguished() {
        let levels = (1...6).compactMap { level -> Int? in
            guard case let .heading(parsed, _)? = blocks(String(repeating: "#", count: level) + " h").first else {
                return nil
            }
            return parsed
        }

        XCTAssertEqual(levels, [1, 2, 3, 4, 5, 6])
    }

    func testParagraphCarriesEmphasisCodeStrikethroughAndLinks() throws {
        guard case let .paragraph(inlines) = try XCTUnwrap(
            blocks("plain **bold** *italic* `code` ~~gone~~ [label](https://example.com)").first
        ) else {
            return XCTFail("expected a paragraph")
        }

        func span(_ text: String) throws -> AgentMarkdownInline {
            try XCTUnwrap(inlines.first { $0.text == text }, "no span reading \(text)")
        }
        XCTAssertTrue(try span("bold").isStronglyEmphasized)
        XCTAssertTrue(try span("italic").isEmphasized)
        XCTAssertTrue(try span("code").isCode)
        XCTAssertTrue(try span("gone").isStrikethrough)
        XCTAssertEqual(try span("label").link, URL(string: "https://example.com"))
        // The unstyled words are still unstyled: emphasis must not leak.
        XCTAssertTrue(try span("plain ").intent.isEmpty)
    }

    func testFencedCodeBlockKeepsItsLanguageAndItsExactText() throws {
        guard case let .codeBlock(language, code) = try XCTUnwrap(
            blocks("```swift\nlet x = 1\nfunc f() {}\n```").first
        ) else {
            return XCTFail("expected a code block")
        }

        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1\nfunc f() {}\n")
    }

    func testFenceWithNoInfoStringHasNoLanguage() throws {
        guard case let .codeBlock(language, _) = try XCTUnwrap(blocks("```\nplain\n```").first) else {
            return XCTFail("expected a code block")
        }

        XCTAssertNil(language)
    }

    func testBulletListItemsKeepTheirOrder() throws {
        guard case let .list(list) = try XCTUnwrap(blocks("- alpha\n- beta").first) else {
            return XCTFail("expected a list")
        }

        XCTAssertFalse(list.isOrdered)
        XCTAssertEqual(list.items.map(\.ordinal), [1, 2])
        XCTAssertEqual(list.items.map { plainText($0.blocks) }, ["alpha", "beta"])
    }

    func testOrderedListKeepsTheOrdinalsTheSourceWrote() throws {
        // Markdown renumbers from the first ordinal; what matters is that the
        // renderer prints what the parser reports rather than counting itself.
        guard case let .list(list) = try XCTUnwrap(blocks("3. three\n4. four").first) else {
            return XCTFail("expected a list")
        }

        XCTAssertTrue(list.isOrdered)
        XCTAssertEqual(list.items.map(\.ordinal), [3, 4])
    }

    func testNestedListsNest() throws {
        guard case let .list(outer) = try XCTUnwrap(blocks("- a\n  - b").first),
              case let .list(inner) = try XCTUnwrap(outer.items.first?.blocks.last)
        else {
            return XCTFail("expected a list inside a list item")
        }

        XCTAssertEqual(plainText(inner.items.first?.blocks ?? []), "b")
    }

    func testBlockQuoteWrapsItsOwnBlocks() throws {
        guard case let .blockQuote(inner) = try XCTUnwrap(blocks("> quoted\n>\n> - listed").first) else {
            return XCTFail("expected a block quote")
        }

        XCTAssertEqual(inner.count, 2)
        guard case .paragraph = inner[0], case .list = inner[1] else {
            return XCTFail("expected a paragraph then a list inside the quote")
        }
    }

    func testThematicBreakIsItsOwnBlock() {
        XCTAssertEqual(blocks("above\n\n---\n\nbelow").count, 3)
        guard case .thematicBreak = blocks("above\n\n---\n\nbelow")[1] else {
            return XCTFail("expected a rule between the two paragraphs")
        }
    }

    func testTableKeepsPerColumnAlignment() throws {
        guard case let .table(table) = try XCTUnwrap(
            blocks("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |").first
        ) else {
            return XCTFail("expected a table")
        }

        XCTAssertEqual(table.columns, [.leading, .center, .trailing])
        XCTAssertEqual(table.header?.map { $0.map(\.text).joined() }, ["a", "b", "c"])
        XCTAssertEqual(table.rows.map { $0.map { $0.map(\.text).joined() } }, [["1", "2", "3"]])
    }

    func testTableCellsKeepTheirInlineStyling() throws {
        guard case let .table(table) = try XCTUnwrap(
            blocks("| a |\n|---|\n| `x` |").first
        ) else {
            return XCTFail("expected a table")
        }

        XCTAssertTrue(try XCTUnwrap(table.rows.first?.first?.first).isCode)
    }

    // MARK: - Malformed and partial input, which is the normal case

    func testAFenceThatNeverClosesStillRendersWhatWasWritten() throws {
        // The transcript is tail-followed, so an agent mid-write leaves exactly
        // this. Losing the body would blank the message the user is watching.
        let parsed = blocks("before\n\n```swift\nlet x = 1\nlet y = 2")

        XCTAssertEqual(parsed.count, 2)
        guard case let .codeBlock(language, code) = parsed[1] else {
            return XCTFail("expected the unterminated fence to still be a code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1\nlet y = 2\n")
    }

    func testAnUnterminatedTableRowIsPaddedToTheColumnCount() throws {
        guard case let .table(table) = try XCTUnwrap(blocks("| a | b |\n|---|---|\n| 1 |").first) else {
            return XCTFail("expected a table")
        }

        XCTAssertEqual(table.columns.count, 2)
        // Every row is rectangular, so nothing downstream indexes past its end.
        XCTAssertEqual(table.rows.map(\.count), [2])
        XCTAssertEqual(table.rows[0][1].map(\.text).joined(), "")
    }

    func testATableCutOffBeforeItsDelimiterRowIsStillText() {
        // Only a header line has arrived; GFM has no table yet, and the text
        // must survive as prose rather than disappearing.
        XCTAssertEqual(plainText(blocks("| a | b |")), "| a | b |")
    }

    func testEmptyAndWhitespaceOnlySourcesProduceNothing() {
        XCTAssertTrue(blocks("").isEmpty)
        XCTAssertTrue(blocks("   \n\n  ").isEmpty)
    }

    func testTextThatMerelyLooksLikeMarkdownStaysOneParagraph() {
        let source = "use 2 * 3 * 4 and a_b_c and C:\\path and 5 > 3"

        let parsed = blocks(source)

        XCTAssertEqual(parsed.count, 1)
        guard case .paragraph = parsed[0] else {
            return XCTFail("expected a plain paragraph")
        }
        XCTAssertEqual(plainText(parsed), source)
    }

    func testRawHtmlBlocksAreKeptAsText() {
        // Foundation hands these back with no presentation intent at all, which
        // is exactly the shape a naive tree builder drops on the floor.
        XCTAssertTrue(plainText(blocks("a\n\n<div>block</div>\n\nb")).contains("<div>block</div>"))
    }

    func testAgentMarkupTagsSurviveAsVisibleText() {
        XCTAssertEqual(
            plainText(blocks("<my-element>hello</my-element>")),
            "<my-element>hello</my-element>"
        )
    }

    func testHardAndSoftBreaksStayInsideTheirParagraph() throws {
        guard case let .paragraph(soft) = try XCTUnwrap(blocks("one\ntwo").first),
              case let .paragraph(hard) = try XCTUnwrap(blocks("one  \ntwo").first)
        else {
            return XCTFail("expected paragraphs")
        }

        XCTAssertTrue(soft.contains { $0.isBreak })
        XCTAssertTrue(hard.contains { $0.isBreak })
        XCTAssertEqual(hard.first(where: \.isBreak)?.text, "\n")
    }

    func testALongPlainMessageIsNotRestructured() {
        // Most transcript messages are prose. Any of them turning into a
        // heading or a list would be a rendering bug users would see first.
        let source = String(repeating: "An ordinary sentence about the failure. ", count: 20)

        let parsed = blocks(source)

        XCTAssertEqual(parsed.count, 1)
        guard case .paragraph = parsed[0] else {
            return XCTFail("expected one paragraph")
        }
    }
}

/// Which blocks share a view and which earn one of their own.
final class AgentMarkdownSegmentPlannerTests: XCTestCase {
    private func segments(_ source: String) -> [AgentMarkdownSegment] {
        AgentMarkdownSegmentPlanner.segments(for: AgentTranscriptMarkdown.document(source))
    }

    func testAdjacentProseBlocksCoalesceIntoOneSegment() {
        // The cost model: a message of headings, paragraphs and simple lists
        // costs one view no matter how many blocks it holds.
        let planned = segments("# Title\n\npara one\n\n- a\n- b\n\npara two")

        XCTAssertEqual(planned.count, 1)
        guard case let .flow(blocks) = planned[0] else {
            return XCTFail("expected one flow segment")
        }
        XCTAssertEqual(blocks.count, 4)
    }

    func testACodeBlockAndATableBreakTheFlowRun() {
        let planned = segments("intro\n\n```swift\nlet x = 1\n```\n\n| a |\n|---|\n| 1 |\n\noutro")

        XCTAssertEqual(planned.count, 4)
        guard case .flow = planned[0], case .code = planned[1],
              case .table = planned[2], case .flow = planned[3]
        else {
            return XCTFail("expected flow, code, table, flow — got \(planned)")
        }
    }

    func testAQuoteAndARuleGetTheirOwnSegments() {
        let planned = segments("> quoted\n\n---\n\nafter")

        XCTAssertEqual(planned.count, 3)
        guard case .nested(.quote, _) = planned[0], case .rule = planned[1] else {
            return XCTFail("expected a quote then a rule — got \(planned)")
        }
    }

    func testAListCarryingACodeBlockBecomesOneSegmentPerItem() {
        // A tab stop cannot hold a code block, so the whole list has to become
        // views; each item keeps its marker.
        let planned = segments("1. first\n2. second\n\n   ```swift\n   let x = 1\n   ```")

        let markers = planned.compactMap { segment -> String? in
            guard case let .nested(.listItem(marker), _) = segment else { return nil }
            return marker
        }
        XCTAssertEqual(markers, ["1.", "2."])
    }

    func testAnEmptyDocumentPlansNothing() {
        XCTAssertTrue(segments("").isEmpty)
    }
}

/// Column geometry, asserted as arithmetic before it is asserted as pixels.
final class AgentMarkdownTableLayoutTests: XCTestCase {
    private let minimum: CGFloat = 44

    func testColumnsFillTheWidthKeepingTheirProportions() {
        // A table has a header band behind its first row; columns that stopped
        // short of the band's edge would read as a broken layout.
        let widths = AgentMarkdownTableLayout.columnWidths(
            natural: [100, 60],
            available: 400,
            minimum: minimum
        )

        XCTAssertEqual(widths.reduce(0, +), 400, accuracy: 0.01)
        XCTAssertEqual(widths[0] / widths[1], 100.0 / 60.0, accuracy: 0.01)
    }

    func testColumnsShrinkInProportionWhenTheyDoNotFit() {
        let widths = AgentMarkdownTableLayout.columnWidths(
            natural: [300, 100],
            available: 200,
            minimum: minimum
        )

        XCTAssertEqual(widths[0], 150, accuracy: 0.01)
        XCTAssertEqual(widths[1], 50, accuracy: 0.01)
    }

    /// The property the whole design hangs on: a table can never push the
    /// document sideways, at any width, with any content.
    func testColumnsNeverExceedTheWidthTheyAreGiven() {
        let cases: [[CGFloat]] = [
            [100, 60],
            [900, 40, 40],
            [500, 500, 500, 500, 500, 500],
            [1, 1, 1],
            [10_000],
        ]
        for natural in cases {
            for available in [80.0, 200.0, 640.0, 1_600.0] as [CGFloat] {
                let widths = AgentMarkdownTableLayout.columnWidths(
                    natural: natural,
                    available: available,
                    minimum: minimum
                )
                XCTAssertLessThanOrEqual(
                    widths.reduce(0, +),
                    available + 0.01,
                    "natural \(natural) at \(available)pt summed to \(widths.reduce(0, +))"
                )
                XCTAssertEqual(widths.count, natural.count)
            }
        }
    }

    func testManyNarrowColumnsFallBackToAnEvenSplitRatherThanOverflowing() {
        let widths = AgentMarkdownTableLayout.columnWidths(
            natural: [200, 200, 200, 200],
            available: 100,
            minimum: minimum
        )

        XCTAssertEqual(widths, [25, 25, 25, 25])
    }

    func testNoColumnsIsNoWidths() {
        XCTAssertTrue(AgentMarkdownTableLayout.columnWidths(natural: [], available: 400, minimum: minimum).isEmpty)
    }
}

/// Rendering decisions asserted against laid-out frames.
///
/// Constraint-reading has missed layout bugs in this repo twice; these measure
/// instead.
@MainActor
final class AgentMarkdownRenderingTests: XCTestCase {
    private func laidOut(_ source: String, width: CGFloat = 420) -> AgentMarkdownDocumentView {
        let view = AgentMarkdownDocumentView(
            blocks: AgentTranscriptMarkdown.document(source),
            theme: .dark,
            insetX: DesignTokens.Component.agentTranscriptRowInsetXPX,
            insetY: DesignTokens.Component.agentTranscriptRowInsetYPX
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 2_000))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return view
    }

    private func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) throws -> T {
        func find(_ candidate: NSView) -> T? {
            if let hit = candidate as? T { return hit }
            for child in candidate.subviews { if let hit = find(child) { return hit } }
            return nil
        }
        return try XCTUnwrap(find(view))
    }

    func testProseCostsExactlyOneView() {
        // The whole reason headings and lists are paragraph styles rather than
        // views: the common message must not get heavier.
        let view = laidOut("# Title\n\nA paragraph with **bold** in it.\n\n- one\n- two")

        XCTAssertEqual(view.segmentViewsForTesting.count, 1)
        XCTAssertTrue(view.segmentViewsForTesting[0] is NSTextField)
    }

    func testACodeBlockDoesNotWrapAndDoesNotWidenTheDocument() throws {
        let line = "let veryLongIdentifierName = someFunctionCall(withA: 1, andB: 2, andC: 3, andD: 4)"
        let view = laidOut("```swift\n\(line)\n```", width: 200)
        let code = try firstDescendant(AgentMarkdownCodeBlockView.self, in: view)

        // The code reaches past the pane, which is what the horizontal scroller
        // inside the block is for.
        XCTAssertGreaterThan(code.contentSize.width, code.bounds.width)
        // And it is still one line tall: it overflowed rather than reflowed.
        XCTAssertEqual(
            code.contentSize.height,
            DesignTokens.Component.agentTranscriptCodeLineHeightPX,
            accuracy: 0.5
        )
        // The document itself stayed inside the width it was given.
        XCTAssertEqual(view.bounds.width, 200, accuracy: 0.5)
        XCTAssertLessThanOrEqual(code.frame.maxX, view.bounds.width + 0.5)
    }

    func testACodeBlockIsAsTallAsItsLineCount() throws {
        let view = laidOut("```\na\nb\nc\n```")
        let code = try firstDescendant(AgentMarkdownCodeBlockView.self, in: view)

        XCTAssertEqual(
            code.contentSize.height,
            DesignTokens.Component.agentTranscriptCodeLineHeightPX * 3,
            accuracy: 0.5
        )
    }

    /// Every cell placed against the exact column box it belongs to. Alignment
    /// is only observable as geometry, so this is measured rather than read off
    /// a `NSTextAlignment` property that might never reach the screen.
    func testTableCellsSitWhereTheirColumnAlignmentSays() throws {
        // Header words are much wider than the body cells beneath them, so
        // every column box has slack and the three alignments are separable.
        let view = laidOut("""
        | leading heading | centred heading | trailing heading |
        |:--|:-:|--:|
        | x | y | z |
        """, width: 700)
        let table = try firstDescendant(AgentMarkdownTableView.self, in: view)
        let frames = table.cellFramesForTesting
        let widths = table.columnWidthsForTesting
        let padX = DesignTokens.Component.agentTranscriptTableCellPaddingXPX

        XCTAssertEqual(frames.count, 2, "expected a header row and one body row")
        XCTAssertEqual(widths.count, 3)

        var boxX: CGFloat = 0
        let boxes = widths.map { width -> (start: CGFloat, content: CGFloat) in
            let box = (start: boxX + padX, content: width - padX * 2)
            boxX += width
            return box
        }

        for (rowIndex, row) in frames.enumerated() {
            XCTAssertEqual(row.count, 3)
            let context = "row \(rowIndex)"

            XCTAssertEqual(row[0].minX, boxes[0].start, accuracy: 0.5, "leading, \(context)")

            let slack = boxes[1].content - row[1].width
            XCTAssertEqual(
                row[1].minX,
                boxes[1].start + slack / 2,
                accuracy: 0.5,
                "centred, \(context)"
            )

            XCTAssertEqual(
                row[2].maxX,
                boxes[2].start + boxes[2].content,
                accuracy: 0.5,
                "trailing, \(context)"
            )
        }

        // And the body row's short cells really did have slack to be moved
        // within, or the three assertions above would all be the same claim.
        XCTAssertLessThan(frames[1][1].width, boxes[1].content)
        XCTAssertGreaterThan(frames[1][2].minX, boxes[2].start)
    }

    func testATableNeverReachesPastTheWidthItWasGiven() throws {
        for width in [180.0, 320.0, 900.0] as [CGFloat] {
            let view = laidOut("""
            | an extremely long first column header | another long second column header |
            |---|---|
            | with a similarly long body cell in it | and a second long body cell here |
            """, width: width)
            let table = try firstDescendant(AgentMarkdownTableView.self, in: view)

            for row in table.cellFramesForTesting {
                for frame in row {
                    XCTAssertLessThanOrEqual(
                        frame.maxX,
                        table.bounds.width + 0.5,
                        "at \(width)pt a cell reached \(frame.maxX) in a \(table.bounds.width)pt table"
                    )
                }
            }
        }
    }

    func testATableIsTallerThanNothing() throws {
        let view = laidOut("| a |\n|---|\n| 1 |")
        let table = try firstDescendant(AgentMarkdownTableView.self, in: view)

        XCTAssertGreaterThan(table.bounds.height, 0)
        XCTAssertGreaterThan(view.bounds.height, table.bounds.height)
    }

    func testAMessageMixingProseCodeAndATableResolvesToOneViewPerConstruct() {
        let view = laidOut("intro\n\n```swift\nlet x = 1\n```\n\n| a |\n|---|\n| 1 |\n\noutro")

        XCTAssertEqual(view.segmentViewsForTesting.count, 4)
        XCTAssertTrue(view.segmentViewsForTesting[1] is AgentMarkdownCodeBlockView)
        XCTAssertTrue(view.segmentViewsForTesting[2] is AgentMarkdownTableView)
    }

    func testAnEmptyDocumentStillHasAResolvedHeight() {
        let view = laidOut("")

        XCTAssertTrue(view.segmentViewsForTesting.isEmpty)
        XCTAssertEqual(
            view.bounds.height,
            DesignTokens.Component.agentTranscriptRowInsetYPX * 2,
            accuracy: 0.5
        )
    }

    func testHeadingsRenderLargerThanBodyText() throws {
        let view = laidOut("# Big\n\nsmall")
        let label = try XCTUnwrap(view.segmentViewsForTesting.first as? NSTextField)
        let attributed = label.attributedStringValue

        let headingFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bodyFont = attributed.attribute(
            .font,
            at: attributed.length - 1,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertGreaterThan(
            try XCTUnwrap(headingFont).pointSize,
            try XCTUnwrap(bodyFont).pointSize
        )
    }

    func testALinkIsAttributedAsOne() throws {
        let view = laidOut("see [docs](https://example.com)")
        let label = try XCTUnwrap(view.segmentViewsForTesting.first as? NSTextField)

        var found: URL?
        label.attributedStringValue.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: label.attributedStringValue.length)
        ) { value, _, _ in
            found = value as? URL ?? found
        }
        XCTAssertEqual(found, URL(string: "https://example.com"))
    }

    func testACodeBlockWithAnUnknownLanguageStillRenders() throws {
        let view = laidOut("```brainfuck\n+++\n```")

        XCTAssertNoThrow(try firstDescendant(AgentMarkdownCodeBlockView.self, in: view))
    }
}

/// The diff path the renderer must leave alone.
@MainActor
final class AgentTranscriptDiffColouringTests: XCTestCase {
    func testRemovedAndAddedLinesKeepTheirOpposedColours() {
        let theme = DesignTokens.ChromeTheme.dark
        let diff = AgentTranscriptDiff(filePath: "/tmp/a.swift", lines: [
            .init(kind: .removed, text: "old"),
            .init(kind: .added, text: "new"),
        ])

        let attributed = AgentSessionTranscriptView.diffAttributedString(diff, theme: theme)

        var colours: [NSColor] = []
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let colour = value as? NSColor { colours.append(colour) }
        }
        XCTAssertEqual(colours, [theme.error, theme.success])
        XCTAssertEqual(attributed.string, "- old\n+ new\n")
    }

    func testDiffTextIsMonospaced() throws {
        let attributed = AgentSessionTranscriptView.diffAttributedString(
            AgentTranscriptDiff(filePath: "a", lines: [.init(kind: .added, text: "x")]),
            theme: .dark
        )

        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }
}

/// Fence info strings to the highlighter's own language vocabulary.
final class CodeSyntaxLanguageHintTests: XCTestCase {
    func testCommonFenceHintsMapToLanguages() {
        let expected: [String: CodeSyntaxLanguage] = [
            "swift": .swift,
            "python": .python,
            "bash": .shell,
            "zsh": .shell,
            "typescript": .javascript,
            "rust": .rust,
            "golang": .go,
            "go": .go,
            "json": .json,
            "yml": .yaml,
            "cpp": .c,
        ]
        for (hint, language) in expected {
            XCTAssertEqual(CodeSyntaxLanguage(markdownLanguageHint: hint), language, "hint \(hint)")
        }
    }

    func testAnInfoStringWithAttributesStillResolves() {
        XCTAssertEqual(
            CodeSyntaxLanguage(markdownLanguageHint: "swift title=Foo.swift"),
            .swift
        )
    }

    func testUnknownAndEmptyHintsDegradeToPlain() {
        XCTAssertEqual(CodeSyntaxLanguage(markdownLanguageHint: ""), .plain)
        XCTAssertEqual(CodeSyntaxLanguage(markdownLanguageHint: "brainfuck"), .plain)
    }
}
