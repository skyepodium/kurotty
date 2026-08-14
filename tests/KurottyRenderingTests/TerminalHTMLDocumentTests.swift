import XCTest
import KurottyCore
@testable import KurottyApp

/// The projection is the whole rendering decision, so these hold it to the two
/// properties that decide whether an HTML terminal is viable at all: it must
/// emit few nodes, and it must keep the grid a grid.
final class TerminalHTMLDocumentTests: XCTestCase {
    private enum Fixture {
        static let columns = 80
        static let rows = 24
        static let white = SIMD4<Float>(1, 1, 1, 1)
        static let black = SIMD4<Float>(0, 0, 0, 1)
        static let red = SIMD4<Float>(1, 0, 0, 1)
    }

    private func frame(
        cells: [TerminalCell],
        decorations: [TerminalDecoration] = [],
        columns: Int = Fixture.columns,
        visibleRows: Int = Fixture.rows
    ) -> TerminalFrame {
        TerminalFrame(
            cells: cells,
            backgrounds: [],
            decorations: decorations,
            defaultForeground: Fixture.white,
            defaultBackground: Fixture.black,
            dirtyRows: [],
            dirtyRects: [],
            isFullDamage: true,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: TerminalTextSelectionRange(location: 0, length: 0),
            columns: columns,
            visibleRows: visibleRows,
            cellSize: TerminalFrameSize(width: 8, height: 16),
            padding: TerminalFramePoint(x: 0, y: 0)
        )
    }

    private func line(_ text: String, row: Int = 0, foreground: SIMD4<Float>? = nil) -> [TerminalCell] {
        text.enumerated().map { offset, character in
            TerminalCell(
                character: character,
                column: offset,
                row: row,
                foreground: foreground ?? Fixture.white,
                background: Fixture.black
            )
        }
    }

    // MARK: - Coalescing, which is what makes this viable

    func testAPlainLineIsOneRunRatherThanOneRunPerCell() {
        let runs = TerminalHTMLDocument.runs(row: 0, frame: frame(cells: line("hello world")))

        XCTAssertEqual(
            runs.count,
            1,
            "a uniform line must not become one node per column; that is what makes DOM terminals slow"
        )
        XCTAssertTrue(runs[0].text.hasPrefix("hello world"))
    }

    func testARunBreaksExactlyWhereAColourChanges() {
        var cells = line("red", row: 0, foreground: Fixture.red)
        cells += line("white", row: 0).map {
            TerminalCell(character: $0.character, column: $0.column + 3, row: 0, foreground: Fixture.white, background: Fixture.black)
        }

        let runs = TerminalHTMLDocument.runs(row: 0, frame: frame(cells: cells))

        XCTAssertEqual(runs.count, 2, "one break, at the colour change")
        XCTAssertEqual(runs[0].text, "red")
        XCTAssertTrue(runs[1].text.hasPrefix("white"))
    }

    func testAnEmptyScreenIsOneRunPerRow() {
        let rendered = TerminalHTMLDocument.rows(frame: frame(cells: []))

        XCTAssertEqual(rendered.count, Fixture.rows)
        for row in 0..<Fixture.rows {
            XCTAssertEqual(TerminalHTMLDocument.runs(row: row, frame: frame(cells: [])).count, 1)
        }
    }

    func testAFullScreenOfProseStaysWellUnderANodePerCell() {
        // A worst case that is still realistic: every row a sentence, with a
        // highlighted word in the middle. If this approaches columns * rows the
        // renderer is not viable and the number should say so out loud.
        var cells: [TerminalCell] = []
        for row in 0..<Fixture.rows {
            cells += line("the quick brown fox jumps over the lazy dog ", row: row)
            cells += line("HIGHLIGHT", row: row, foreground: Fixture.red).map {
                TerminalCell(character: $0.character, column: $0.column + 44, row: row, foreground: Fixture.red, background: Fixture.black)
            }
        }

        let built = frame(cells: cells)
        let total = (0..<Fixture.rows).reduce(0) { $0 + TerminalHTMLDocument.runs(row: $1, frame: built).count }
        let cellCount = Fixture.columns * Fixture.rows

        XCTAssertLessThan(total, cellCount / 10, "coalescing must cut node count by an order of magnitude, got \(total) for \(cellCount) cells")
    }

    // MARK: - The grid has to stay a grid

    func testAWideGlyphOccupiesTwoColumns() {
        let cells = [
            TerminalCell(character: "한", column: 0, row: 0, foreground: Fixture.white, background: Fixture.black),
            TerminalCell(character: "a", column: 2, row: 0, foreground: Fixture.white, background: Fixture.black),
        ]

        let runs = TerminalHTMLDocument.runs(row: 0, frame: frame(cells: cells))
        let width = runs.reduce(0) { $0 + $1.columns }

        XCTAssertEqual(width, Fixture.columns, "every row must account for exactly the terminal's columns")

        // The total is 80 whichever width the syllable is given, because the
        // walk advances by whatever it believes — so the total cannot detect
        // this and the text is what does. Two cells wide means the
        // continuation at column 1 is stepped over, and `a` follows the
        // syllable directly. One cell wide would render that continuation as a
        // space and produce `한 a`, which is the bug: every following column on
        // the line shifted by one.
        XCTAssertTrue(
            runs.first?.text.hasPrefix("한a") == true,
            "a wide glyph must consume its continuation cell, got \(runs.first?.text.prefix(4) ?? "")"
        )
    }

    func testEveryRowAccountsForEveryColumn() {
        let built = frame(cells: line("mixed 한글 and ascii"))

        for row in 0..<Fixture.rows {
            let width = TerminalHTMLDocument.runs(row: row, frame: built).reduce(0) { $0 + $1.columns }
            XCTAssertEqual(width, Fixture.columns, "row \(row) drifted")
        }
    }

    func testARunCarriesItsWidthInCellUnits() {
        let html = TerminalHTMLDocument.row(0, frame: frame(cells: line("abc")))

        XCTAssertTrue(
            html.contains("width:calc(var(--cw) *"),
            "a run sized by the font rather than by cells will drift away from the grid"
        )
    }

    // MARK: - Terminal output is arbitrary bytes

    func testScreenContentThatLooksLikeMarkupIsRenderedAsText() {
        let html = TerminalHTMLDocument.row(0, frame: frame(cells: line("<script>x</script>")))

        XCTAssertFalse(html.contains("<script>"), "a program printing a tag must not inject one")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testAmpersandIsNotDoubleEscaped() {
        let html = TerminalHTMLDocument.row(0, frame: frame(cells: line("a && b")))

        XCTAssertTrue(html.contains("a &amp;&amp; b"))
        XCTAssertFalse(html.contains("&amp;amp;"))
    }

    func testAQuoteCannotCloseTheStyleAttribute() {
        let html = TerminalHTMLDocument.row(0, frame: frame(cells: line("\"><b>")))

        XCTAssertFalse(html.contains("\"><b>"))
        XCTAssertTrue(html.contains("&quot;"))
    }

    // MARK: - Colour

    func testAColourOutOfRangeIsClampedRatherThanEmitted() {
        // A component above one would produce rgba(256,…), which browsers drop
        // entirely — the cell would inherit a colour instead of showing a wrong
        // one, and a silently inherited colour is much harder to notice.
        let css = TerminalHTMLDocument.css(SIMD4<Float>(2, -1, 0.5, 3))

        XCTAssertTrue(css.hasPrefix("rgba(255,0,128"), "got \(css)")
        XCTAssertTrue(css.hasSuffix("1.000)"), "got \(css)")
    }

    func testRowsAreIdentifiedSoDamageCanPatchThem() {
        let rendered = TerminalHTMLDocument.rows(frame: frame(cells: line("x")))

        XCTAssertTrue(rendered[0].contains("id=\"r0\""))
        XCTAssertTrue(rendered[5].contains("id=\"r5\""))
    }

    // MARK: - Decorations that are text styles

    func testUnderlineAndStrikethroughReachTheRunAndBoxDrawingDoesNot() {
        let decorations = [
            TerminalDecoration(column: 0, row: 0, width: 2, kind: .underline, color: Fixture.white),
            TerminalDecoration(column: 4, row: 0, width: 1, kind: .strikethrough, color: Fixture.white),
            TerminalDecoration(column: 6, row: 0, width: 1, kind: .boxDrawing(left: true, right: true, up: false, down: false), color: Fixture.white),
        ]

        let built = frame(cells: line("abcdefgh"), decorations: decorations)
        let runs = TerminalHTMLDocument.runs(row: 0, frame: built)

        XCTAssertTrue(runs.contains { $0.isUnderlined }, "underline is a text style and belongs on the run")
        XCTAssertTrue(runs.contains { $0.isStruckThrough })
        // Box drawing is a glyph shape the atlas draws, not a style; it must not
        // silently become an underline.
        XCTAssertEqual(runs.filter(\.isUnderlined).reduce(0) { $0 + $1.columns }, 2)
    }
}

/// Writes the markup the renderer actually produces to `kshot/sample-frame.html`.
///
/// Exists because the rendered screenshots are indistinguishable from the Metal
/// ones — which is the goal, and which also means a picture cannot answer "is
/// this really HTML?". The markup can.
final class TerminalHTMLSampleTests: XCTestCase {
    func testWriteSampleMarkup() throws {
        guard ProcessInfo.processInfo.environment["KUROTTY_WRITE_HTML_SAMPLE"] == "1" else {
            throw XCTSkip("set KUROTTY_WRITE_HTML_SAMPLE=1 to regenerate the sample")
        }

        let prompt = "skyepodium  ~/dev  $ ls -la"
        var cells: [TerminalCell] = []
        for (offset, character) in prompt.enumerated() {
            cells.append(TerminalCell(
                character: character,
                column: offset,
                row: 0,
                foreground: offset < 10 ? SIMD4<Float>(0.4, 0.7, 1, 1) : SIMD4<Float>(1, 1, 1, 1),
                background: offset < 10 ? SIMD4<Float>(0.15, 0.15, 0.2, 1) : SIMD4<Float>(0, 0, 0, 1)
            ))
        }

        let frame = TerminalFrame(
            cells: cells,
            backgrounds: [],
            decorations: [],
            defaultForeground: SIMD4<Float>(1, 1, 1, 1),
            defaultBackground: SIMD4<Float>(0, 0, 0, 1),
            dirtyRows: [], dirtyRects: [], isFullDamage: true,
            cursorColumn: prompt.count, cursorRow: 0, cursorBlinkOn: true,
            markedTextColumn: 0, markedText: "",
            markedTextSelectedRange: TerminalTextSelectionRange(location: 0, length: 0),
            columns: 60, visibleRows: 2,
            cellSize: TerminalFrameSize(width: 12, height: 26),
            padding: TerminalFramePoint(x: 0, y: 0)
        )

        let markup = TerminalHTMLDocument.rows(frame: frame).joined(separator: "\n")
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kshot/sample-frame.html")
        try markup.write(to: path, atomically: true, encoding: .utf8)
        print("wrote \(path.path)")
    }
}
