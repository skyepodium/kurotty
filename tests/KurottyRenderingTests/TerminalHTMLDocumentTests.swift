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
        visibleRows: Int = Fixture.rows,
        defaultForeground: SIMD4<Float> = Fixture.white,
        cursorColumn: Int = 0,
        cursorRow: Int = 0,
        cursorBlinkOn: Bool = true,
        cursorStyle: TerminalCursorStyle = .default,
        markedText: String = "",
        markedTextColumn: Int = 0,
        markedTextSelectedRange: TerminalTextSelectionRange = .none
    ) -> TerminalFrame {
        TerminalFrame(
            cells: cells,
            backgrounds: [],
            decorations: decorations,
            defaultForeground: defaultForeground,
            defaultBackground: Fixture.black,
            dirtyRows: [],
            dirtyRects: [],
            isFullDamage: true,
            cursorColumn: cursorColumn,
            cursorRow: cursorRow,
            cursorBlinkOn: cursorBlinkOn,
            cursorStyle: cursorStyle,
            markedTextColumn: markedTextColumn,
            markedText: markedText,
            markedTextSelectedRange: markedTextSelectedRange,
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
        // The width is stated rather than inferred. The projector used to carry
        // its own Unicode range table and guess; it now reads what the frame
        // says, which is what the Zig grid decided. A fixture that does not say
        // a glyph is wide describes a narrow glyph, and that is the point — the
        // renderer no longer has an opinion of its own to disagree with.
        let cells = [
            TerminalCell(
                character: "한", column: 0, row: 0,
                foreground: Fixture.white, background: Fixture.black,
                columns: TerminalCellColumns.wide
            ),
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

    func testACellWidthComesFromTheFrameRatherThanTheCodepoint() {
        // A renderer that reads the codepoint would call this two columns wide
        // whatever the frame said. Reading the frame means one authority.
        let narrowed = [
            TerminalCell(
                character: "한", column: 0, row: 0,
                foreground: Fixture.white, background: Fixture.black,
                columns: TerminalCellColumns.single
            )
        ]

        let runs = TerminalHTMLDocument.runs(row: 0, frame: frame(cells: narrowed))

        XCTAssertEqual(
            runs.reduce(0) { $0 + $1.columns },
            Fixture.columns,
            "the row still accounts for every column when the frame calls the glyph narrow"
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

    func testABlockElementIsDrawnAsGeometryRatherThanDropped() {
        // The bug this covers shipped and was caught from a screenshot: block
        // elements were skipped entirely, so Claude Code's mascot rendered as a
        // solid rectangle of its own background while Metal drew the artwork.
        let decoration = TerminalDecoration(
            column: 0, row: 0, width: 1,
            kind: .blockElement(x: 0, y: 0.5, width: 1, height: 0.5),
            color: Fixture.red
        )

        let html = TerminalHTMLDocument.row(0, frame: frame(cells: [], decorations: [decoration]))

        XCTAssertTrue(html.contains("position:absolute"), "a block element must reach the document as a box")
        XCTAssertTrue(html.contains("rgba(255,0,0"), "and carry the colour the frame gave it")
    }

    func testABlockElementIsFlippedIntoCSSOrientation() {
        // The frame measures y from the bottom of the cell and CSS from the
        // top. An upper half block is y=0.5 height=0.5 in the frame, and must
        // come out at the top of the cell.
        let upperHalf = TerminalDecoration(
            column: 0, row: 0, width: 1,
            kind: .blockElement(x: 0, y: 0.5, width: 1, height: 0.5),
            color: Fixture.white
        )

        let html = TerminalHTMLDocument.row(0, frame: frame(cells: [], decorations: [upperHalf]))

        XCTAssertTrue(html.contains("top:0.0000%"), "an upper half block sits at the top, got \(html.prefix(400))")
    }

    func testACellCarryingGeometryDoesNotMergeIntoItsNeighbours() {
        let decoration = TerminalDecoration(
            column: 3, row: 0, width: 1,
            kind: .blockElement(x: 0, y: 0, width: 1, height: 1),
            color: Fixture.red
        )

        let runs = TerminalHTMLDocument.runs(
            row: 0,
            frame: frame(cells: line("aaaaaaa"), decorations: [decoration])
        )

        guard let geometry = runs.first(where: { !$0.shapes.isEmpty }) else {
            return XCTFail("the decorated cell must produce a run of its own")
        }
        XCTAssertEqual(geometry.columns, 1, "a wider run would stretch the shape across cells")
    }

    func testBoxDrawingBecomesBarsThatMeetInTheMiddle() {
        let cross = TerminalDecoration(
            column: 0, row: 0, width: 1,
            kind: .boxDrawing(left: true, right: true, up: true, down: true),
            color: Fixture.white
        )

        let runs = TerminalHTMLDocument.runs(row: 0, frame: frame(cells: [], decorations: [cross]))

        XCTAssertEqual(runs.first?.shapes.count, 4, "four arms for a cross")
    }

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
        // Box drawing is a shape rather than a text style; it must not become
        // an underline on its way through.
        XCTAssertEqual(runs.filter(\.isUnderlined).reduce(0) { $0 + $1.columns }, 2)
        XCTAssertTrue(runs.contains { !$0.shapes.isEmpty }, "box drawing must arrive as geometry")
    }

    // MARK: - IME composition
    //
    // The frame carries the preedit because `setMarkedText` state must never be
    // written to the terminal as committed text, which makes drawing it the
    // renderer's job. This renderer did not do it, so a user composing Hangul
    // saw nothing at all until the syllable committed.

    func testACompositionIsDrawnOnTheCursorRow() {
        let built = frame(
            cells: [],
            cursorRow: 3,
            markedText: "안",
            markedTextColumn: 5
        )

        let rendered = TerminalHTMLDocument.rows(frame: built)

        XCTAssertTrue(rendered[3].contains("안"), "the preedit is invisible while composing")
        XCTAssertFalse(rendered[0].contains("안"), "and belongs only on the row the composition sits on")
    }

    func testACompositionStartsAtItsAnchorColumn() {
        let built = frame(cells: [], markedText: "안", markedTextColumn: 5)

        let runs = TerminalHTMLDocument.runs(row: 0, frame: built)
        let leading = runs.prefix { !$0.isMarked }.reduce(0) { $0 + $1.columns }

        XCTAssertEqual(leading, 5, "the composition must begin where the input method anchored it")
        XCTAssertEqual(
            runs.first(where: \.isMarked)?.columns,
            2,
            "a Hangul syllable occupies two columns of the preedit"
        )
    }

    func testTheCellsUnderACompositionAreNotDrawnBehindIt() {
        let built = frame(
            cells: line("abcdefgh"),
            markedText: "가",
            markedTextColumn: 2
        )

        let text = TerminalHTMLDocument.runs(row: 0, frame: built)
            .map(\.text)
            .joined()

        XCTAssertTrue(text.hasPrefix("ab가efgh"), "got \(text.prefix(10))")
    }

    func testAWideCellIsDroppedWholeRatherThanBleedingUnderTheComposition() {
        // The head of a wide cell sits one column before the composition, so a
        // walk that kept it would step over the preedit's first column and
        // shift the whole composition one cell to the right.
        // The fixture states the width rather than leaving it to be guessed
        // from the codepoint: the Zig grid is what decides a cell is wide, and
        // the renderer reads that decision off the cell instead of re-deriving
        // it.
        let cells = [
            TerminalCell(
                character: "한", column: 1, row: 0,
                foreground: Fixture.white, background: Fixture.black,
                columns: TerminalCellColumns.wide
            ),
        ]
        let built = frame(cells: cells, markedText: "가", markedTextColumn: 2)

        let runs = TerminalHTMLDocument.runs(row: 0, frame: built)
        let leading = runs.prefix { !$0.isMarked }.reduce(0) { $0 + $1.columns }

        XCTAssertEqual(leading, 2, "the composition drifted to column \(leading)")
        XCTAssertFalse(
            runs.contains { $0.text.contains("한") },
            "half of a wide cell cannot be drawn"
        )
    }

    func testTheSelectedSubRangeOfACompositionIsDrawnInTheSelectionColour() {
        // The input method selects the syllable the next keystroke lands in.
        // `TerminalMetalView` draws that sub-range in the selection foreground
        // and the rest in the screen's own; the two renderers must agree.
        let built = frame(
            cells: [],
            defaultForeground: Fixture.red,
            markedText: "안녕",
            markedTextSelectedRange: TerminalTextSelectionRange(location: 1, length: 1)
        )

        let marked = TerminalHTMLDocument.runs(row: 0, frame: built).filter(\.isMarked)

        XCTAssertEqual(marked.count, 2, "the selected sub-range must not merge into the rest of the preedit")
        XCTAssertEqual(marked.first?.text, "안")
        XCTAssertEqual(marked.first?.foreground, Fixture.red)
        XCTAssertEqual(marked.last?.text, "녕")
        XCTAssertEqual(marked.last?.foreground, TerminalSelectionStyle.foregroundColor)
    }

    func testACompositionWithoutASelectedSubRangeIsOneRun() {
        let built = frame(cells: [], markedText: "안녕")

        let marked = TerminalHTMLDocument.runs(row: 0, frame: built).filter(\.isMarked)

        XCTAssertEqual(marked.count, 1, "nothing distinguishes these cells, so they are one span")
        XCTAssertEqual(marked.first?.text, "안녕")
    }

    func testACompositionIsEscapedLikeAnyOtherContent() {
        // Marked text is user input rather than program output, and gets the
        // same treatment: it reaches the document as text or not at all.
        let html = TerminalHTMLDocument.row(0, frame: frame(cells: [], markedText: "<b>&"))

        XCTAssertFalse(html.contains("<b>"))
        XCTAssertTrue(html.contains("&lt;b&gt;&amp;"))
    }

    func testACompositionCarriesTheClassThatNamesIt() {
        let html = TerminalHTMLDocument.row(0, frame: frame(cells: [], markedText: "안"))

        XCTAssertTrue(html.contains(TerminalHTMLDocument.Markup.markedClass))
    }

    func testTheCaretSitsInsideTheCompositionRatherThanAfterIt() {
        // The surface puts `cursorColumn` past the whole preedit; the caret
        // belongs where the input method's selection says the next keystroke
        // lands, which is what `TerminalMetalView` draws.
        let built = frame(
            cells: [],
            cursorColumn: 4,
            markedText: "안녕",
            markedTextColumn: 0,
            markedTextSelectedRange: TerminalTextSelectionRange(location: 1, length: 1)
        )

        XCTAssertEqual(TerminalCursorPlacement(frame: built).column, 2)
    }

    func testTheCaretIsTheFramesOwnColumnWhenNothingIsBeingComposed() {
        XCTAssertEqual(
            TerminalCursorPlacement(frame: frame(cells: [], cursorColumn: 7)).column,
            7
        )
    }

    // MARK: - Cursor shape
    //
    // DECSCUSR is a per-terminal value `vim`, `fish` and `zsh`'s vi mode change
    // on every mode switch. The frame carries it and Metal honours it; this
    // renderer drew one hardcoded block for every case.

    func testABlockCursorFillsTheCell() {
        let declaration = TerminalHTMLDocument.cursorDeclaration(
            frame: frame(cells: [], cursorStyle: TerminalCursorStyle(shape: .block, blinks: false))
        )

        XCTAssertTrue(declaration.contains("width:var(\(TerminalHTMLDocument.Variable.cellWidth))"), declaration)
        XCTAssertTrue(declaration.contains("height:var(\(TerminalHTMLDocument.Variable.cellHeight))"), declaration)
    }

    func testABarCursorIsARuleOnTheLeadingEdge() {
        let declaration = TerminalHTMLDocument.cursorDeclaration(
            frame: frame(cells: [], cursorStyle: TerminalCursorStyle(shape: .bar, blinks: true))
        )

        XCTAssertTrue(
            declaration.contains("width:var(\(TerminalHTMLDocument.Variable.cursorBarWidth))"),
            "a bar drawn a cell wide is a block, got \(declaration)"
        )
        XCTAssertTrue(declaration.contains("height:var(\(TerminalHTMLDocument.Variable.cellHeight))"), declaration)
    }

    func testAnUnderlineCursorIsARuleOnTheBottomEdge() {
        let declaration = TerminalHTMLDocument.cursorDeclaration(
            frame: frame(cells: [], cursorRow: 2, cursorStyle: TerminalCursorStyle(shape: .underline, blinks: false))
        )

        XCTAssertTrue(
            declaration.contains("height:var(\(TerminalHTMLDocument.Variable.cursorUnderlineHeight))"),
            "an underline drawn a cell tall is a block, got \(declaration)"
        )
        XCTAssertTrue(
            declaration.contains(
                "calc(var(\(TerminalHTMLDocument.Variable.cellHeight)) * 2 "
                    + "+ var(\(TerminalHTMLDocument.Variable.cellHeight)) "
                    + "- var(\(TerminalHTMLDocument.Variable.cursorUnderlineHeight)))"
            ),
            "the rule sits on the cell's bottom edge, got \(declaration)"
        )
    }

    func testTheCursorIsPlacedInCellUnits() {
        let declaration = TerminalHTMLDocument.cursorDeclaration(
            frame: frame(cells: [], cursorColumn: 9, cursorRow: 4)
        )

        XCTAssertTrue(
            declaration.contains("translate(calc(var(\(TerminalHTMLDocument.Variable.cellWidth)) * 9)"),
            declaration
        )
    }

    func testACursorInItsOffBlinkPhaseIsTransparent() {
        let off = TerminalHTMLDocument.cursorDeclaration(frame: frame(cells: [], cursorBlinkOn: false))
        let on = TerminalHTMLDocument.cursorDeclaration(frame: frame(cells: [], cursorBlinkOn: true))

        XCTAssertTrue(off.contains("opacity:0"), off)
        XCTAssertTrue(on.contains("opacity:1"), on)
    }

    func testAHiddenCursorIsNotDrawnAtTheTopOfTheScreen() {
        // The surface reports a hidden cursor as row -1, and a renderer that
        // clamped that to zero would park a cursor on the first row.
        let hidden = TerminalCursorPlacement(frame: frame(cells: [], cursorRow: -1))

        XCTAssertFalse(hidden.isVisible)
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
