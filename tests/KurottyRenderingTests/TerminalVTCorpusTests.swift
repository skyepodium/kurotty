import KurottyCore
import XCTest
@testable import KurottyApp

/// The VT corpus from `tests/core_tests.zig`, pointed at the interpreter that
/// actually renders.
///
/// The Zig suite is the better VT corpus in this repo — fragmented CSI/OSC
/// reassembly, oversized-buffer resync, CJK wide cells, combining marks — but
/// it exercises `src/`, whose parse result was discarded before it reached a
/// pixel. These cases assert the same VT behaviour against
/// `TerminalOutputInterpreter`: screen contents, cursor, styles. Each test names
/// the Zig case it came from so the two can be compared.
///
/// Cases the Swift interpreter does not implement are skipped with the observed
/// behaviour recorded, not quietly weakened.
final class TerminalVTCorpusTests: XCTestCase {
    // MARK: - Fixtures

    @MainActor
    private func makeInterpreter(
        rows: Int,
        columns: Int,
        responses: TerminalVTResponseRecorder? = nil
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.screen.resize(rows: rows, columns: columns)
        interpreter.lastSentSize = TerminalSize(columns: columns, rows: rows)
        interpreter.resetScrollRegion()
        if let responses {
            interpreter.host = TerminalOutputInterpreterHost(
                sendTerminalResponse: { responses.terminalResponses.append($0) },
                respondToOscQuery: { _ in },
                dispatchTerminalIntegrationOsc: { _ in .ignored },
                publishTitle: {},
                handleTerminalIntegrationEvent: { _ in },
                handleDesktopNotificationEvent: { _ in },
                handleClipboardWriteEvent: { _ in },
                ringTerminalBell: {},
                updateScrollIndicator: {},
                maxScrollbackOffset: { _ in 0 },
                reportTerminalFocusIfNeeded: {},
                terminalCapabilityMetrics: { nil },
                terminalColorSchemeMode: { .dark }
            )
        }
        return interpreter
    }

    /// The Zig corpus reads rows as text via `grid.rowText`. This is the
    /// equivalent: a wide cell's continuation slot holds a space, so a row of
    /// `한A` reads back as `"한 A"`.
    @MainActor
    private func rowText(_ interpreter: TerminalOutputInterpreter, _ row: Int) -> String {
        String(interpreter.screen.cells[row].map(\.character))
    }

    // MARK: - Fragmented sequence reassembly

    /// Zig: "parser keeps incomplete CSI until final byte arrives".
    @MainActor
    func testFragmentedCSIAppliesOnlyOnceItsFinalByteArrives() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("ab\u{1b}[31")
        XCTAssertEqual(rowText(interpreter, 0).prefix(3), "ab ")

        interpreter.interpret(";1m!")
        XCTAssertEqual(rowText(interpreter, 0).prefix(3), "ab!")
        XCTAssertEqual(interpreter.cursorColumn, 3)

        // Parameters apply in order, so `31` picks the normal red before `1`
        // turns on bold — the bright variant would mean they were reordered.
        XCTAssertEqual(interpreter.screen.cells[0][2].style.foreground, DesignTokens.Color.ansiNormal[1])
        XCTAssertTrue(interpreter.screen.cells[0][2].style.bold)
        XCTAssertEqual(interpreter.screen.cells[0][0].style.foreground, TerminalTextStyle.default.foreground)
    }

    /// Zig: "parser keeps incomplete OSC until BEL or string terminator arrives".
    @MainActor
    func testFragmentedOSCSetsTheTitleOnlyAtItsTerminator() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)
        let originalTitle = interpreter.terminalTitle

        interpreter.interpret("prefix\u{1b}]0;kur")
        XCTAssertEqual(interpreter.terminalTitle, originalTitle)
        XCTAssertEqual(rowText(interpreter, 0).prefix(6), "prefix")

        interpreter.interpret("otty")
        XCTAssertEqual(interpreter.terminalTitle, originalTitle)

        interpreter.interpret("\u{1b}\\suffix")
        XCTAssertEqual(interpreter.terminalTitle, "kurotty")
        XCTAssertEqual(rowText(interpreter, 0).prefix(12), "prefixsuffix")

        interpreter.interpret("\u{1b}]1;tab\u{7}")
        XCTAssertEqual(interpreter.terminalTitle, "tab")
        XCTAssertEqual(rowText(interpreter, 0).prefix(12), "prefixsuffix")
    }

    /// Zig: "parser preserves fragmented device attribute prefixes without
    /// printable leakage". The Swift observable is stronger than the Zig one:
    /// the query is answered, so the sequence was understood rather than eaten.
    @MainActor
    func testFragmentedDeviceAttributeQueriesAnswerWithoutLeakingToTheScreen() {
        let responses = TerminalVTResponseRecorder()
        let interpreter = makeInterpreter(rows: 1, columns: 20, responses: responses)

        interpreter.interpret("\u{1b}[")
        interpreter.interpret(">0")
        interpreter.interpret("cX\u{1b}[?1;2")
        interpreter.interpret("c")

        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "X ")
        XCTAssertEqual(interpreter.cursorColumn, 1)
        XCTAssertEqual(responses.terminalResponses, ["\u{1b}[>0;0;0c"])
    }

    /// Zig: "parser suppresses charset designators used by tmux terminfo".
    @MainActor
    func testCharsetDesignatorsAreSuppressed() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("A\u{1b}(BB\u{1b})0C\u{1b}%GD")

        XCTAssertEqual(rowText(interpreter, 0).prefix(4), "ABCD")
        XCTAssertEqual(interpreter.cursorColumn, 4)
    }

    /// Zig: "parser suppresses fragmented charset designators without printable
    /// leakage". The designator's second byte is consumed across the split, so
    /// the `B` in the second chunk is the designator argument, not text.
    @MainActor
    func testFragmentedCharsetDesignatorsDoNotLeakOntoTheScreen() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("A\u{1b}(")
        interpreter.interpret("BC\u{1b})")
        interpreter.interpret("0D")

        XCTAssertEqual(rowText(interpreter, 0).prefix(3), "ACD")
        XCTAssertEqual(interpreter.cursorColumn, 3)
    }

    /// Zig: "parser suppresses fragmented DEC private two byte escapes without
    /// printable leakage".
    @MainActor
    func testFragmentedDECPrivateTwoByteEscapeDoesNotLeakOntoTheScreen() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("A\u{1b}#")
        interpreter.interpret("8B")

        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "AB")
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    // MARK: - Oversized sequences and parameter overflow

    /// Zig: "parser bounds oversized CSI buffers and resynchronizes at the final
    /// byte". Swift does not bound the buffer (see
    /// `testUnterminatedCSIBufferIsBounded`), but it must still resynchronise.
    @MainActor
    func testOversizedCSIResynchronizesAtTheFinalByte() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("\u{1b}[" + String(repeating: "1", count: 5_000))
        XCTAssertEqual(interpreter.cursorColumn, 0)

        interpreter.interpret("mok")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "ok")
    }

    /// Zig: "parser bounds oversized OSC buffers and resynchronizes at string
    /// terminator".
    @MainActor
    func testOversizedOSCResynchronizesAtTheStringTerminator() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("\u{1b}]0;" + String(repeating: "x", count: 5_000))
        XCTAssertEqual(interpreter.cursorColumn, 0)

        interpreter.interpret("\u{1b}\\ok")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "ok")
    }

    /// Zig: "parser clamps an oversized CSI parameter instead of aborting". This
    /// is the `\e[99999m` abort that reached production through `core.feed`;
    /// the interpreter that renders must not garble the surrounding text either.
    @MainActor
    func testOversizedSGRParameterLeavesSurroundingTextIntact() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("hello\u{1b}[99999m world")

        XCTAssertEqual(rowText(interpreter, 0).prefix(11), "hello world")
    }

    /// Zig: "parser survives an oversized parameter mid-stream and keeps
    /// parsing".
    @MainActor
    func testOversizedCursorPositionParameterClampsAndKeepsParsing() {
        let interpreter = makeInterpreter(rows: 4, columns: 10)

        interpreter.interpret("\u{1b}[70000;5H")
        XCTAssertEqual(interpreter.cursorRow, 3)
        XCTAssertEqual(interpreter.cursorColumn, 4)

        interpreter.interpret("ok")
        XCTAssertEqual(rowText(interpreter, 3), "    ok    ")
    }

    // MARK: - Cursor, erase and editing

    /// Zig: "grid applies printable text, cursor movement, and erase in
    /// display".
    @MainActor
    func testPrintableTextCursorMovementAndEraseInDisplay() {
        let interpreter = makeInterpreter(rows: 3, columns: 4)

        interpreter.interpret("abcdef\u{1b}[1;3HXY\u{1b}[J")

        XCTAssertEqual(rowText(interpreter, 0), "abXY")
        XCTAssertEqual(rowText(interpreter, 1), "    ")
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 4)
    }

    /// Zig: "grid applies absolute cursor, line erase, insert, delete, and
    /// alternate screen".
    @MainActor
    func testInsertDeleteCharactersLineEraseAndAlternateScreen() {
        let interpreter = makeInterpreter(rows: 3, columns: 5)

        interpreter.interpret("abcde\u{1b}[1;3H\u{1b}[2@")
        XCTAssertEqual(rowText(interpreter, 0), "ab  c")

        interpreter.interpret("\u{1b}[1P")
        XCTAssertEqual(rowText(interpreter, 0), "ab c ")

        interpreter.interpret("\u{1b}[K")
        XCTAssertEqual(rowText(interpreter, 0), "ab   ")

        interpreter.interpret("\u{1b}[?1049h")
        interpreter.interpret("alt")
        XCTAssertEqual(rowText(interpreter, 0), "alt  ")

        interpreter.interpret("\u{1b}[?1049l")
        XCTAssertEqual(rowText(interpreter, 0), "ab   ")
    }

    /// Zig: "ABI alternate screen restores cursor position on leave".
    @MainActor
    func testAlternateScreenRestoresTheCursorPositionOnLeave() {
        let interpreter = makeInterpreter(rows: 4, columns: 10)

        interpreter.interpret("\u{1b}[3;7H\u{1b}[?1049h")
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)

        interpreter.interpret("alt\u{1b}[?1049l")
        XCTAssertEqual(interpreter.cursorRow, 2)
        XCTAssertEqual(interpreter.cursorColumn, 6)
    }

    /// Zig: "ABI CSI parameter defaults are explicit per opcode". A zero
    /// parameter means "the default", not "move by zero".
    @MainActor
    func testCSIParameterDefaultsAreExplicitPerOpcode() {
        let interpreter = makeInterpreter(rows: 4, columns: 10)

        interpreter.interpret("\u{1b}[2;5H")
        XCTAssertEqual(interpreter.cursorRow, 1)
        XCTAssertEqual(interpreter.cursorColumn, 4)

        interpreter.interpret("\u{1b}[H")
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)

        interpreter.interpret("\u{1b}[0B\u{1b}[0C")
        XCTAssertEqual(interpreter.cursorRow, 1)
        XCTAssertEqual(interpreter.cursorColumn, 1)

        interpreter.interpret("ab\u{1b}[3G")
        XCTAssertEqual(interpreter.cursorColumn, 2)

        interpreter.interpret("\u{1b}[K")
        XCTAssertEqual(rowText(interpreter, 1), " a        ")
    }

    /// Zig: "ABI tab control moves the cursor non-destructively". Carriage
    /// return then tab must skip over `b` without erasing it.
    @MainActor
    func testCarriageReturnAndTabMoveTheCursorNonDestructively() {
        let interpreter = makeInterpreter(rows: 2, columns: 20)

        interpreter.interpret("ab\rx\ty")

        XCTAssertEqual(interpreter.cursorColumn, 9)
        XCTAssertEqual(rowText(interpreter, 0).prefix(9), "xb      y")
    }

    /// Zig: "grid restores saved cursor when leaving the alternate screen" has
    /// no direct VT spelling; the reverse-index half of the same cursor
    /// bookkeeping does. RI inside the region moves up without scrolling.
    @MainActor
    func testReverseIndexMovesUpWithoutScrollingInsideTheRegion() {
        let interpreter = makeInterpreter(rows: 3, columns: 5)

        interpreter.interpret("\u{1b}[2;1Habc\u{1b}M")

        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 3)
        XCTAssertEqual(rowText(interpreter, 1), "abc  ")
    }

    // MARK: - Wide cells and combining marks

    /// Zig: "grid gives Korean wide char a head cell plus continuation cell" and
    /// "ABI copy_row_cells reports wide head and continuation widths".
    @MainActor
    func testKoreanWideCharacterOccupiesAHeadAndAContinuationCell() {
        let interpreter = makeInterpreter(rows: 2, columns: 6)

        interpreter.interpret("한A")

        XCTAssertEqual(interpreter.screen.cells[0][0].character, "한")
        XCTAssertFalse(interpreter.screen.cells[0][0].isContinuation)
        XCTAssertTrue(interpreter.screen.cells[0][1].isContinuation)
        XCTAssertEqual(interpreter.screen.cells[0][2].character, "A")
        XCTAssertFalse(interpreter.screen.cells[0][2].isContinuation)
        XCTAssertEqual(interpreter.cursorColumn, 3)
    }

    /// Zig: "grid wraps a wide char that does not fit in the last column".
    @MainActor
    func testWideCharacterThatDoesNotFitTheLastColumnWrapsToTheNextRow() {
        let interpreter = makeInterpreter(rows: 2, columns: 3)

        interpreter.interpret("ab界")

        XCTAssertEqual(rowText(interpreter, 0), "ab ")
        XCTAssertEqual(interpreter.screen.cells[1][0].character, "界")
        XCTAssertTrue(interpreter.screen.cells[1][1].isContinuation)
        XCTAssertEqual(interpreter.cursorRow, 1)
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    /// Zig: "grid overwriting half of a wide char clears its partner cell".
    /// Leaving the orphaned head behind is what produces the doubled-glyph
    /// smear this cell model exists to prevent.
    @MainActor
    func testOverwritingHalfOfAWideCharacterClearsItsPartnerCell() {
        let interpreter = makeInterpreter(rows: 1, columns: 6)

        interpreter.interpret("한")
        interpreter.interpret("\u{1b}[1;2Hx")

        XCTAssertEqual(rowText(interpreter, 0), " x    ")
        XCTAssertEqual(interpreter.screen.cells[0][0].character, " ")
        XCTAssertFalse(interpreter.screen.cells[0][0].isContinuation)
        XCTAssertEqual(interpreter.screen.cells[0][1].character, "x")
    }

    /// Zig: "grid attaches combining mark to previous cell without advancing
    /// the cursor".
    @MainActor
    func testCombiningMarkAttachesToThePreviousCellWithoutAdvancingTheCursor() {
        let interpreter = makeInterpreter(rows: 1, columns: 4)

        interpreter.interpret("a\u{301}b")

        XCTAssertEqual(interpreter.screen.cells[0][0].character, "á")
        XCTAssertEqual(interpreter.screen.cells[0][1].character, "b")
        XCTAssertEqual(interpreter.cursorColumn, 2)
        XCTAssertEqual(rowText(interpreter, 0), "áb  ")
    }

    /// Zig: "grid decodes UTF-8 sequences split across write calls". The
    /// interpreter takes a `String`, so a half-decoded scalar cannot reach it —
    /// the split is resolved one layer down, at the PTY read boundary. That is
    /// where the Zig case ports to, and it had no coverage.
    @MainActor
    func testUTF8ScalarSplitAcrossPTYReadsIsReassembledBeforeInterpretation() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 4_096)
        let scalarBytes = Array("한".utf8)
        XCTAssertEqual(scalarBytes.count, 3)

        buffer.append(Data(scalarBytes.prefix(1)))
        XCTAssertNil(buffer.takeDecodedText(), "a lone lead byte must be held back, not replaced with U+FFFD")

        buffer.append(Data(scalarBytes.dropFirst()))
        let text = buffer.takeDecodedText()
        XCTAssertEqual(text, "한")

        let interpreter = makeInterpreter(rows: 1, columns: 4)
        interpreter.interpret(text ?? "")
        XCTAssertEqual(interpreter.screen.cells[0][0].character, "한")
        XCTAssertTrue(interpreter.screen.cells[0][1].isContinuation)
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    // MARK: - Styles

    /// Zig: "ABI SGR colors and attributes round-trip through copy_row_cells".
    @MainActor
    func testSGRColorsAndAttributesApplyToTheCellsTheyPrecede() {
        let interpreter = makeInterpreter(rows: 2, columns: 8)

        interpreter.interpret("\u{1b}[1;4;31;48;5;200mA\u{1b}[38;2;10;20;30mB\u{1b}[0mC")

        let first = interpreter.screen.cells[0][0]
        XCTAssertEqual(first.character, "A")
        XCTAssertTrue(first.style.bold)
        XCTAssertTrue(first.style.underline)
        XCTAssertFalse(first.style.inverse)
        // Bold is already set when `31` arrives, so the bright ramp is correct.
        XCTAssertEqual(first.style.foreground, DesignTokens.Color.ansiBright[1])
        XCTAssertEqual(first.style.background, TerminalTextStyle.rgb(red: 255, green: 0, blue: 215))

        let second = interpreter.screen.cells[0][1]
        XCTAssertEqual(second.character, "B")
        XCTAssertEqual(second.style.foreground, TerminalTextStyle.rgb(red: 10, green: 20, blue: 30))
        XCTAssertEqual(second.style.background, first.style.background)

        let third = interpreter.screen.cells[0][2]
        XCTAssertEqual(third.character, "C")
        XCTAssertFalse(third.style.bold)
        XCTAssertFalse(third.style.underline)
        XCTAssertEqual(third.style.foreground, TerminalTextStyle.default.foreground)
        XCTAssertEqual(third.style.background, TerminalTextStyle.default.background)
    }

    /// Zig: "ABI ignores private CSI m sequences for text style". `CSI > 4 ; 2 m`
    /// is modifyOtherKeys, not SGR — applying it as SGR would recolour output
    /// every time a TUI negotiates keyboard support.
    @MainActor
    func testPrivateSGRSequencesSetKeyboardModeWithoutChangingTextStyle() {
        let interpreter = makeInterpreter(rows: 1, columns: 8)

        interpreter.interpret("\u{1b}[>4;2mA")

        let cell = interpreter.screen.cells[0][0]
        XCTAssertEqual(cell.character, "A")
        XCTAssertFalse(cell.style.bold)
        XCTAssertEqual(cell.style.foreground, TerminalTextStyle.default.foreground)
        XCTAssertEqual(cell.style.background, TerminalTextStyle.default.background)
        XCTAssertEqual(interpreter.modifyOtherKeysMode, 2)
    }

    /// Zig: "parser handles SGR reset variants and colon color parameters".
    @MainActor
    func testColonSeparatedTruecolorSGRIsAccepted() {
        let interpreter = makeInterpreter(rows: 1, columns: 8)

        interpreter.interpret("\u{1b}[38:2::1:2:3mZ")

        XCTAssertEqual(interpreter.screen.cells[0][0].character, "Z")
        XCTAssertEqual(
            interpreter.screen.cells[0][0].style.foreground,
            TerminalTextStyle.rgb(red: 1, green: 2, blue: 3)
        )
    }

    /// Zig: "parser handles SGR reset variants". A bare `CSI m` is `CSI 0 m`.
    @MainActor
    func testBareSGRResetsToTheDefaultStyle() {
        let interpreter = makeInterpreter(rows: 1, columns: 8)

        interpreter.interpret("\u{1b}[1;31mA\u{1b}[mB")

        XCTAssertTrue(interpreter.screen.cells[0][0].style.bold)
        XCTAssertFalse(interpreter.screen.cells[0][1].style.bold)
        XCTAssertEqual(
            interpreter.screen.cells[0][1].style.foreground,
            TerminalTextStyle.default.foreground
        )
    }

    // MARK: - Gaps the port exposed
    //
    // Each of these is a Zig case with no working Swift equivalent. They are
    // skipped rather than weakened: the assertion that would pass today is the
    // wrong assertion, and writing it down would freeze the bug.

    /// Zig: "grid tab moves cursor to next multiple-of-8 stop without erasing"
    /// — the clamp half.
    @MainActor
    func testTabStopsAreClampedToTheLastColumn() throws {
        // GAP. `interpret`'s HT branch takes `tabStops.filter { $0 > cursorColumn }.min()`
        // with no upper bound, so on a 20-column screen a third tab from column
        // 16 lands the cursor on column 24 — four columns past the screen. The
        // Zig grid clamps to `width - 1` (19). A CPR issued there reports a
        // column that does not exist, and the next printable character wraps
        // from a position the app never moved the cursor to.
        throw XCTSkip("HT is not clamped to the screen width: third tab on a 20-column screen reaches column 24, expected 19")
    }

    /// Zig: "parser suppresses fragmented DCS PM and APC payloads until
    /// terminators" — the DCS third.
    @MainActor
    func testDCSPayloadsAreNotPrintedToTheScreen() throws {
        // GAP. `consumeControl` has no DCS state: ESC P falls through to
        // `default`, which returns the parser to `.normal`, so the payload is
        // treated as text. Feeding `a\ePq1$r` + `q\e\\b` paints `a1$rqb`; a
        // conformant terminal shows `ab`. DECRQSS replies from any TUI that
        // probes for capabilities land on screen as garbage.
        throw XCTSkip("DCS payloads print literally: ESC P has no parser state, giving \"a1$rqb\" where \"ab\" is correct")
    }

    /// Zig: "parser suppresses fragmented DCS PM and APC payloads until
    /// terminators" — the APC third.
    @MainActor
    func testAPCPayloadsAreNotPrintedToTheScreen() throws {
        // GAP. Same cause as DCS: ESC _ has no state. `c\e_apc-ignored\e\\d`
        // paints `capc-ignoredd` instead of `cd`. This is the envelope Kitty
        // graphics and several agent integrations use.
        throw XCTSkip("APC payloads print literally: ESC _ has no parser state, giving \"capc-ignoredd\" where \"cd\" is correct")
    }

    /// Zig: "parser suppresses fragmented DCS PM and APC payloads until
    /// terminators" — the PM third.
    @MainActor
    func testPMPayloadsAreNotPrintedToTheScreen() throws {
        // GAP. Same cause: ESC ^ has no state. `b\e^pm-ignored\ac` paints
        // `bpm-ignoredc` instead of `bc`.
        throw XCTSkip("PM payloads print literally: ESC ^ has no parser state, giving \"bpm-ignoredc\" where \"bc\" is correct")
    }

    /// Zig: "parser keeps OSC open when ESC is not a string terminator".
    @MainActor
    func testOSCInterruptedByANonTerminatorESCDoesNotLeakItsPayload() throws {
        // GAP, and the more damaging half is the leak rather than the
        // divergence. `\e]0;title\eX-suffix\adone` should either keep the OSC
        // open (Zig) or abandon it; Swift abandons it *and* resumes printing
        // mid-payload, so `-suffix` is painted onto the screen and the title is
        // silently dropped. Any OSC carrying an ESC — a title containing one,
        // or a truncated OSC 8 hyperlink — sprays its tail into the output.
        throw XCTSkip("an OSC interrupted by a non-ST ESC paints its remaining payload: got \"-suffixdone\", expected no leakage")
    }

    /// Zig: "parser bounds oversized CSI buffers" / "...oversized OSC buffers"
    /// — the bound, as opposed to the resync that
    /// `testOversizedCSIResynchronizesAtTheFinalByte` covers.
    @MainActor
    func testUnterminatedCSIBufferIsBounded() throws {
        // GAP. `csiBuffer` and `oscBuffer` are plain `String`s that grow for as
        // long as a sequence stays unterminated; the Zig parser caps them at
        // `max_csi_sequence_bytes` / `max_string_sequence_bytes` and discards.
        // Resync is correct either way, so nothing renders wrongly, but a child
        // process emitting `\e[` followed by unbounded digits — or `\e]0;` with
        // no terminator — grows a main-actor String without limit. Unlike the
        // rest of these, this is a memory-exhaustion path, not a rendering bug.
        throw XCTSkip("csiBuffer and oscBuffer are unbounded: an unterminated sequence grows a String without limit")
    }
}

private final class TerminalVTResponseRecorder {
    var terminalResponses: [String] = []
}
