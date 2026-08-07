import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// Behavioural cover for the screen-mutating half of `TerminalOutputInterpreter`:
/// erase, repeat, scroll region, cursor addressing, grapheme handling, and the
/// scrollback feed.
///
/// These replace source-text assertions that used to live in
/// `GlyphRenderingRegressionTests`. Those assertions named VT features —
/// `testEraseLineUsesActiveStyleForClearedCells` was the worst of them — while
/// never running a single escape sequence through the interpreter, so a rename
/// failed them and a behavioural regression did not.
@MainActor
final class TerminalInterpreterScreenMutationTests: XCTestCase {
    private enum Fixture {
        static let rows = 6
        static let columns = 12
        /// Distinct from `.default` in both channels so a cell cleared with the
        /// wrong pen is visibly wrong rather than coincidentally equal.
        static let pen = TerminalTextStyle(
            foreground: SIMD4<Float>(0.9, 0.4, 0.2, 1),
            background: SIMD4<Float>(0.1, 0.3, 0.5, 1)
        )
    }

    private func makeInterpreter(
        rows: Int = Fixture.rows,
        columns: Int = Fixture.columns,
        maxScrollbackRows: Int = 1_000
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: maxScrollbackRows
        )
        interpreter.screen = TerminalScreen(rows: rows, columns: columns)
        interpreter.scrollRegionBottom = rows - 1
        return interpreter
    }

    private func line(_ row: Int, of interpreter: TerminalOutputInterpreter) -> String {
        String(interpreter.screen.cells[row].map(\.character))
    }

    // MARK: - Erase

    /// EL fills with the active SGR pen, not with the default background. `less`
    /// and `vim` status lines depend on this: they set a reverse-video pen and
    /// then erase to end of line to paint the bar.
    func testEraseLineFillsClearedCellsWithTheActiveStyle() {
        let interpreter = makeInterpreter()
        interpreter.interpret("abcdef")
        interpreter.currentStyle = Fixture.pen
        interpreter.cursorColumn = 3
        interpreter.interpret("\u{1b}[K")

        XCTAssertEqual(line(0, of: interpreter), "abc         ")
        XCTAssertEqual(interpreter.screen.cells[0][2].style, .default)
        for column in 3..<Fixture.columns {
            XCTAssertEqual(interpreter.screen.cells[0][column].style, Fixture.pen, "column \(column)")
        }
    }

    func testEraseLineToCursorAndWholeLineAlsoUseTheActiveStyle() {
        let backwards = makeInterpreter()
        backwards.interpret("abcdef")
        backwards.currentStyle = Fixture.pen
        backwards.cursorColumn = 3
        backwards.interpret("\u{1b}[1K")

        XCTAssertEqual(line(0, of: backwards), "    ef      ")
        XCTAssertEqual(backwards.screen.cells[0][0].style, Fixture.pen)
        XCTAssertEqual(backwards.screen.cells[0][3].style, Fixture.pen)
        XCTAssertEqual(backwards.screen.cells[0][4].style, .default)

        let whole = makeInterpreter()
        whole.interpret("abcdef")
        whole.currentStyle = Fixture.pen
        whole.interpret("\u{1b}[2K")

        XCTAssertEqual(line(0, of: whole), String(repeating: " ", count: Fixture.columns))
        XCTAssertEqual(whole.screen.cells[0][0].style, Fixture.pen)
    }

    /// ECH (`CSI n X`) erases exactly n cells at the cursor without moving it —
    /// tmux repaints its status line with it.
    func testEraseCharacterClearsExactlyTheRequestedRunAndLeavesTheCursor() {
        let interpreter = makeInterpreter()
        interpreter.interpret("abcdefgh")
        interpreter.cursorColumn = 2
        interpreter.currentStyle = Fixture.pen
        interpreter.interpret("\u{1b}[3X")

        XCTAssertEqual(line(0, of: interpreter), "ab   fgh    ")
        XCTAssertEqual(interpreter.cursorColumn, 2)
        XCTAssertEqual(interpreter.screen.cells[0][2].style, Fixture.pen)
        XCTAssertEqual(interpreter.screen.cells[0][5].style, .default)
    }

    func testEraseCharacterWithoutAParameterErasesOneCell() {
        let interpreter = makeInterpreter()
        interpreter.interpret("abcdefgh")
        interpreter.cursorColumn = 0
        interpreter.interpret("\u{1b}[X")

        XCTAssertEqual(line(0, of: interpreter), " bcdefgh    ")
    }

    // MARK: - Repeat

    /// REP (`CSI n b`) repeats the preceding graphic character. tmux draws its
    /// status bar padding with it, so without it the bar renders truncated.
    func testRepeatPrecedingGraphicCharacterRepeatsAndAdvancesTheCursor() {
        let interpreter = makeInterpreter()
        interpreter.interpret("x\u{1b}[4b")

        XCTAssertEqual(line(0, of: interpreter), "xxxxx       ")
        XCTAssertEqual(interpreter.cursorColumn, 5)
    }

    func testRepeatCarriesTheStyleOfTheCharacterItRepeats() {
        let interpreter = makeInterpreter()
        interpreter.currentStyle = Fixture.pen
        interpreter.interpret("-")
        interpreter.currentStyle = .default
        interpreter.interpret("\u{1b}[2b")

        XCTAssertEqual(line(0, of: interpreter), "---         ")
        XCTAssertEqual(interpreter.screen.cells[0][1].style, Fixture.pen)
        XCTAssertEqual(interpreter.screen.cells[0][2].style, Fixture.pen)
    }

    /// Wide characters are not repeatable: doubling one would desynchronise the
    /// continuation cells for every column after it.
    func testRepeatIgnoresAWidePrecedingCharacter() {
        let interpreter = makeInterpreter()
        interpreter.interpret("한\u{1b}[3b")

        XCTAssertEqual(interpreter.cursorColumn, 2)
        XCTAssertEqual(String(interpreter.screen.cells[0][2].character), " ")
    }

    // MARK: - Scroll region

    func testSetScrollRegionTracksTheRequestedRowsAndHomesTheCursor() {
        let interpreter = makeInterpreter()
        interpreter.cursorRow = 4
        interpreter.cursorColumn = 5
        interpreter.interpret("\u{1b}[2;5r")

        XCTAssertEqual(interpreter.scrollRegionTop, 1)
        XCTAssertEqual(interpreter.scrollRegionBottom, 4)
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)
    }

    func testResettingTheScrollRegionRestoresTheWholeScreen() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[2;5r")
        interpreter.interpret("\u{1b}[r")

        XCTAssertEqual(interpreter.scrollRegionTop, 0)
        XCTAssertEqual(interpreter.scrollRegionBottom, Fixture.rows - 1)
    }

    /// A line feed on the region's last row scrolls the region only. Rows above
    /// the top and below the bottom must not move — that is what keeps a TUI's
    /// title row and input row pinned.
    func testLineFeedAtTheRegionBottomScrollsOnlyTheRegion() {
        let interpreter = makeInterpreter()
        interpreter.interpret("top\r\n")
        interpreter.interpret("one\r\ntwo\r\nthree\r\n")
        interpreter.interpret("bottom")
        interpreter.interpret("\u{1b}[2;4r")
        interpreter.cursorRow = 3
        interpreter.cursorColumn = 0
        interpreter.interpret("\n")

        XCTAssertEqual(line(0, of: interpreter), "top         ")
        XCTAssertEqual(line(1, of: interpreter), "two         ")
        XCTAssertEqual(line(2, of: interpreter), "three       ")
        XCTAssertEqual(line(3, of: interpreter), String(repeating: " ", count: Fixture.columns))
        XCTAssertEqual(line(4, of: interpreter), "bottom      ")
        XCTAssertEqual(interpreter.cursorRow, 3)
    }

    func testScrollUpAndScrollDownHonourTheActiveRegion() {
        let up = makeInterpreter()
        up.interpret("a\r\nb\r\nc\r\nd\r\ne")
        up.interpret("\u{1b}[2;4r")
        up.interpret("\u{1b}[S")

        XCTAssertEqual(line(0, of: up), "a           ")
        XCTAssertEqual(line(1, of: up), "c           ")
        XCTAssertEqual(line(3, of: up), String(repeating: " ", count: Fixture.columns))
        XCTAssertEqual(line(4, of: up), "e           ")

        let down = makeInterpreter()
        down.interpret("a\r\nb\r\nc\r\nd\r\ne")
        down.interpret("\u{1b}[2;4r")
        down.interpret("\u{1b}[T")

        XCTAssertEqual(line(0, of: down), "a           ")
        XCTAssertEqual(line(1, of: down), String(repeating: " ", count: Fixture.columns))
        XCTAssertEqual(line(2, of: down), "b           ")
        XCTAssertEqual(line(4, of: down), "e           ")
    }

    /// IL/DL are clipped by the region bottom, so a TUI that inserts a line in
    /// its transcript pane cannot push content into a reserved input row.
    func testInsertAndDeleteLinesAreClippedByTheRegionBottom() {
        let insert = makeInterpreter()
        insert.interpret("a\r\nb\r\nc\r\nd\r\ne")
        insert.interpret("\u{1b}[2;4r")
        insert.cursorRow = 1
        insert.interpret("\u{1b}[L")

        XCTAssertEqual(line(1, of: insert), String(repeating: " ", count: Fixture.columns))
        XCTAssertEqual(line(2, of: insert), "b           ")
        XCTAssertEqual(line(3, of: insert), "c           ")
        XCTAssertEqual(line(4, of: insert), "e           ")

        let delete = makeInterpreter()
        delete.interpret("a\r\nb\r\nc\r\nd\r\ne")
        delete.interpret("\u{1b}[2;4r")
        delete.cursorRow = 1
        delete.interpret("\u{1b}[M")

        XCTAssertEqual(line(1, of: delete), "c           ")
        XCTAssertEqual(line(2, of: delete), "d           ")
        XCTAssertEqual(line(3, of: delete), String(repeating: " ", count: Fixture.columns))
        XCTAssertEqual(line(4, of: delete), "e           ")
    }

    // MARK: - Scrollback

    /// A top-anchored region still feeds scrollback: Codex-style TUIs reserve
    /// the bottom rows with DECSTBM but scroll their transcript from row 0, and
    /// those lines have to stay reachable.
    func testTopAnchoredScrollRegionFeedsScrollback() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[1;4r")
        interpreter.interpret("first\r\nsecond\r\nthird\r\nfourth")
        interpreter.interpret("\r\nfifth")

        XCTAssertEqual(interpreter.scrollbackRows.count, 1)
        let firstScrollbackRow = interpreter.scrollbackRows.row(at: 0) ?? []
        XCTAssertEqual(
            String(firstScrollbackRow.map(\.character)).trimmingCharacters(in: .whitespaces),
            "first"
        )
    }

    func testARegionThatDoesNotStartAtTheTopDoesNotFeedScrollback() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[2;4r")
        interpreter.interpret("first\r\nsecond\r\nthird\r\nfourth")
        interpreter.interpret("\r\nfifth")

        XCTAssertEqual(interpreter.scrollbackRows.count, 0)
    }

    /// The bound is enforced as rows are appended, not by a later sweep, so a
    /// long-running `yes` cannot grow the store past the limit even briefly.
    func testScrollbackIsBoundedWhileRowsAreAppended() {
        let interpreter = makeInterpreter(maxScrollbackRows: 4)
        interpreter.cursorRow = Fixture.rows - 1
        for index in 0..<20 {
            interpreter.interpret("\rrow\(index)\n")
        }

        XCTAssertEqual(interpreter.scrollbackRows.count, 4)
        // 20 line feeds from the bottom row of a 6-row screen scroll off row0
        // through row14; only the last four survive the bound.
        let oldestRetained = interpreter.scrollbackRows.row(at: 0) ?? []
        XCTAssertEqual(
            String(oldestRetained.map(\.character)).trimmingCharacters(in: .whitespaces),
            "row11"
        )
    }

    // MARK: - Cursor addressing

    func testCursorAddressingMovesAndSubsequentPrintablesOverwriteInPlace() {
        let interpreter = makeInterpreter()
        interpreter.interpret("abcdef")
        interpreter.interpret("\u{1b}[3D")
        interpreter.interpret("XY")

        XCTAssertEqual(line(0, of: interpreter), "abcXYf      ")
        XCTAssertEqual(interpreter.cursorColumn, 5)
    }

    func testColumnAddressingIsOneBasedAndClampedToTheScreen() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[5G")
        XCTAssertEqual(interpreter.cursorColumn, 4)

        interpreter.interpret("\u{1b}[99G")
        XCTAssertEqual(interpreter.cursorColumn, Fixture.columns - 1)

        interpreter.interpret("\u{1b}[`")
        XCTAssertEqual(interpreter.cursorColumn, 0)
    }

    func testCursorPositionIsOneBasedInBothAxes() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[3;7H")

        XCTAssertEqual(interpreter.cursorRow, 2)
        XCTAssertEqual(interpreter.cursorColumn, 6)
    }

    /// Origin mode makes CUP relative to the scroll region; without it a TUI
    /// that reserves rows addresses the wrong line after every repaint.
    func testOriginModeAddressesRelativeToTheScrollRegion() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[2;5r")
        interpreter.interpret("\u{1b}[?6h")
        interpreter.interpret("\u{1b}[1;1H")

        XCTAssertEqual(interpreter.cursorRow, 1)
    }

    /// A printable write replaces the whole cell style. It used to preserve the
    /// previous background, which left prompt-coloured fragments behind after
    /// the prompt was overwritten.
    func testPrintableWriteReplacesThePreviousCellStyleEntirely() {
        let interpreter = makeInterpreter()
        interpreter.currentStyle = Fixture.pen
        interpreter.interpret("abc")
        interpreter.cursorColumn = 0
        interpreter.currentStyle = .default
        interpreter.interpret("z")

        XCTAssertEqual(interpreter.screen.cells[0][0].style, .default)
        XCTAssertEqual(interpreter.screen.cells[0][1].style, Fixture.pen)
    }

    // MARK: - Grapheme clusters and wide cells

    /// Printables are consumed as grapheme clusters, so a combining mark folds
    /// into the base character's cell instead of taking one of its own.
    func testCombiningMarkFoldsIntoThePrecedingCell() {
        let interpreter = makeInterpreter()
        interpreter.interpret("e\u{0301}f")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "e\u{0301}")
        XCTAssertEqual(String(interpreter.screen.cells[0][1].character), "f")
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    /// A combining mark arriving in a later write still has to reach the cell it
    /// belongs to rather than opening a new one.
    func testCombiningMarkSplitAcrossWritesStillFoldsIntoItsBaseCell() {
        let interpreter = makeInterpreter()
        interpreter.interpret("e")
        interpreter.interpret("\u{0301}")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "e\u{0301}")
        XCTAssertEqual(interpreter.cursorColumn, 1)
    }

    func testHangulOccupiesTwoColumnsWithAContinuationCell() {
        let interpreter = makeInterpreter()
        interpreter.interpret("한글")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), "한")
        XCTAssertTrue(interpreter.screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(interpreter.screen.cells[0][2].character), "글")
        XCTAssertTrue(interpreter.screen.cells[0][3].isContinuation)
        XCTAssertEqual(interpreter.cursorColumn, 4)
    }

    /// Overwriting either half of a wide cell must clear both halves; a stray
    /// continuation is what produced the split-Hangul artefacts.
    /// The width policy the interpreter and both renderers share: width is read
    /// from the cluster's first base scalar, so a combining mark cannot widen or
    /// narrow the cell it attaches to.
    func testColumnWidthIsDecidedByTheClustersFirstBaseScalar() {
        XCTAssertEqual(Character("a").terminalColumnWidth, 1)
        XCTAssertEqual(Character("한").terminalColumnWidth, 2)
        XCTAssertEqual(Character("界").terminalColumnWidth, 2)
        XCTAssertEqual("e\u{0301}".first?.terminalColumnWidth, 1)
        XCTAssertEqual("한\u{0301}".first?.terminalColumnWidth, 2)
        // A cluster made only of combining marks takes no column of its own.
        XCTAssertEqual(Character("\u{0301}").terminalColumnWidth, 0)
        XCTAssertEqual("한글".terminalColumnWidth, 4)
    }

    func testOverwritingHalfOfAWideCellClearsBothHalves() {
        let interpreter = makeInterpreter()
        interpreter.interpret("한글")
        interpreter.cursorColumn = 1
        interpreter.interpret("x")

        XCTAssertEqual(String(interpreter.screen.cells[0][0].character), " ")
        XCTAssertFalse(interpreter.screen.cells[0][0].isContinuation)
        XCTAssertEqual(String(interpreter.screen.cells[0][1].character), "x")
        XCTAssertEqual(String(interpreter.screen.cells[0][2].character), "글")
    }
}
