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
/// Where the two parsers disagree on purpose — an ESC inside an OSC, BEL
/// inside a DCS — the Swift case says so and cites what it follows instead.
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
                dispatchTerminalIntegrationOsc: {
                    responses.oscCommands.append($0)
                    return .ignored
                },
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

    // MARK: - String-control envelopes and parser bounds
    //
    // Each of these was a Zig case with no working Swift equivalent when the
    // corpus was ported. They are now behavioural: the screen, the cursor, the
    // reported cursor position, and what reaches the OSC dispatcher.

    /// Zig: "grid tab moves cursor to next multiple-of-8 stop without erasing"
    /// — the clamp half.
    ///
    /// `tabStops` holds every multiple of 8 up to 992 regardless of the pane
    /// width, so an unclamped HT walks off the screen: the third tab on a
    /// 20-column screen used to reach column 24. CPR is the observable that
    /// matters, because a column outside the screen is a column the app is
    /// then told about.
    @MainActor
    func testTabStopsAreClampedToTheLastColumn() {
        let responses = TerminalVTResponseRecorder()
        let interpreter = makeInterpreter(rows: 1, columns: 20, responses: responses)

        interpreter.interpret("\t")
        XCTAssertEqual(interpreter.cursorColumn, 8)

        interpreter.interpret("\t")
        XCTAssertEqual(interpreter.cursorColumn, 16)

        // Stop 24 is past the last column, so HT stops at the right margin.
        interpreter.interpret("\t")
        XCTAssertEqual(interpreter.cursorColumn, 19)

        // Every further tab is a no-op rather than a further walk off-screen.
        interpreter.interpret("\t\t")
        XCTAssertEqual(interpreter.cursorColumn, 19)

        interpreter.interpret("\u{1b}[6n")
        XCTAssertEqual(responses.terminalResponses, ["\u{1b}[1;20R"])
    }

    /// Zig: "parser suppresses fragmented DCS PM and APC payloads until
    /// terminators" — the DCS third.
    ///
    /// The payload is a DECRQSS probe (`DCS $ q ... ST`), which is what a TUI
    /// asking for the current SGR state sends. Kurotty swallows DCS rather
    /// than answering it, so the fix is that nothing is painted, not that a
    /// reply is produced.
    @MainActor
    func testDCSPayloadsAreNotPrintedToTheScreen() {
        let responses = TerminalVTResponseRecorder()
        let interpreter = makeInterpreter(rows: 1, columns: 20, responses: responses)

        interpreter.interpret("a\u{1b}P1$r")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "a ")

        interpreter.interpret("q\u{1b}\\b")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "ab")
        XCTAssertEqual(interpreter.cursorColumn, 2)
        XCTAssertEqual(responses.terminalResponses, [])
    }

    /// Zig: "parser suppresses fragmented DCS PM and APC payloads until
    /// terminators" — the APC third. This is the envelope Kitty graphics uses.
    @MainActor
    func testAPCPayloadsAreNotPrintedToTheScreen() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("c\u{1b}_Ga=T,f=100;iVBORw0KGgoAAAANSUhEUg")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "c ")

        interpreter.interpret("AAAAEAAAABCAYAAAAfFcSJ\u{1b}\\d")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "cd")
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    /// Zig: "parser suppresses fragmented DCS PM and APC payloads until
    /// terminators" — the PM third, plus the terminator question the Zig case
    /// answers differently.
    ///
    /// BEL closes an OSC and nothing else. ECMA-48 §8.3.94 closes PM with ST,
    /// and xterm's `CASE_BELL` only dispatches when `string_mode == ANSI_OSC`;
    /// in any other string mode it rings the bell and keeps accumulating.
    /// `src/parser.zig` treats BEL as a terminator for every string control,
    /// so the two parsers disagree on this input by design.
    @MainActor
    func testPMPayloadsAreNotPrintedToTheScreen() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("b\u{1b}^pm")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "b ")

        interpreter.interpret("-ignored\u{7}still-ignored")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "b ")

        interpreter.interpret("\u{1b}\\c")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "bc")
        XCTAssertEqual(interpreter.cursorColumn, 2)
    }

    /// Zig: "parser keeps OSC open when ESC is not a string terminator".
    ///
    /// Kurotty diverges from the Zig parser here and follows xterm: an ESC
    /// inside a string abandons it. The byte after the ESC still names a
    /// sequence, though — `ESC X` is SOS (ECMA-48 §8.3.128) — so the tail
    /// belongs to that string control rather than to the screen, and SOS is
    /// closed by ST alone, so the BEL does not release it either. Nothing is
    /// painted and the half-read title is dropped rather than applied.
    @MainActor
    func testOSCInterruptedByANonTerminatorESCDoesNotLeakItsPayload() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)
        let originalTitle = interpreter.terminalTitle

        interpreter.interpret("\u{1b}]0;title\u{1b}X-suffix\u{7}done")

        XCTAssertEqual(interpreter.terminalTitle, originalTitle)
        XCTAssertEqual(rowText(interpreter, 0), String(repeating: " ", count: 20))
        XCTAssertEqual(interpreter.cursorColumn, 0)

        // ST closes the SOS, and the stream resynchronizes.
        interpreter.interpret("\u{1b}\\ok")
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "ok")
    }

    /// The ESC that abandons an OSC is re-dispatched, so a CSI arriving inside
    /// an unterminated OSC is executed instead of being eaten with the
    /// payload. `\e]8;;http://…` truncated by a TUI redraw is the shape that
    /// reaches this path in practice.
    @MainActor
    func testCSIInterruptingAnOSCIsExecutedRatherThanSwallowed() {
        let interpreter = makeInterpreter(rows: 1, columns: 20)

        interpreter.interpret("\u{1b}]8;;https://example.com\u{1b}[31mA")

        XCTAssertEqual(rowText(interpreter, 0).prefix(1), "A")
        XCTAssertEqual(interpreter.screen.cells[0][0].style.foreground, DesignTokens.Color.ansiNormal[1])
        XCTAssertNil(interpreter.screen.cells[0][0].linkURL)
    }

    /// Zig: "parser bounds oversized CSI buffers" — the bound, as opposed to
    /// the resync that `testOversizedCSIResynchronizesAtTheFinalByte` covers.
    ///
    /// Overflow discards rather than truncates: executing `CSI <first 256
    /// bytes> H` would move the cursor somewhere the program never asked for.
    @MainActor
    func testOversizedCSIParametersAreDiscardedRatherThanExecuted() {
        let interpreter = makeInterpreter(rows: 4, columns: 10)

        let overflowingParameters = String(
            repeating: "1",
            count: AppConstants.Terminal.maximumCsiParameterBytes + 1
        )
        interpreter.interpret("\u{1b}[" + overflowingParameters + ";5H")
        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)

        interpreter.interpret("ok")
        XCTAssertEqual(rowText(interpreter, 0), "ok        ")
    }

    /// The other half of the bound: a long-but-legal CSI must still execute.
    /// The cap is a memory backstop, and a backstop that eats real sequences
    /// is a worse bug than the one it fixes.
    @MainActor
    func testLongButBoundedSGRSequenceStillApplies() {
        let interpreter = makeInterpreter(rows: 1, columns: 10)

        // `0;` pairs up to two bytes short of the cap, then the colour that has
        // to survive.
        let padding = String(
            repeating: "0;",
            count: (AppConstants.Terminal.maximumCsiParameterBytes - 2) / 2
        )
        interpreter.interpret("\u{1b}[" + padding + "31mA")

        XCTAssertEqual(interpreter.screen.cells[0][0].character, "A")
        XCTAssertEqual(interpreter.screen.cells[0][0].style.foreground, DesignTokens.Color.ansiNormal[1])
    }

    /// Zig: "parser bounds oversized OSC buffers". An overflowing title is
    /// dropped whole rather than applied truncated, and the parser still
    /// resynchronizes at the string terminator.
    @MainActor
    func testOversizedOSCPayloadIsDiscardedRatherThanApplied() {
        let responses = TerminalVTResponseRecorder()
        let interpreter = makeInterpreter(rows: 1, columns: 20, responses: responses)
        let originalTitle = interpreter.terminalTitle

        let overflowingTitle = String(
            repeating: "x",
            count: AppConstants.Terminal.maximumStringPayloadBytes + 1
        )
        interpreter.interpret("\u{1b}]0;" + overflowingTitle + "\u{1b}\\ok")

        XCTAssertEqual(interpreter.terminalTitle, originalTitle)
        XCTAssertEqual(responses.oscCommands, [])
        XCTAssertEqual(rowText(interpreter, 0).prefix(2), "ok")
    }

    /// The other half of the OSC bound. An OSC 52 clipboard write carrying a
    /// realistic selection — 192 KiB of text, so 256 KiB of base64 — must
    /// reach the dispatcher byte for byte.
    @MainActor
    func testLargeOSC52ClipboardPayloadIsNotTruncatedByTheBound() {
        let responses = TerminalVTResponseRecorder()
        let interpreter = makeInterpreter(rows: 1, columns: 20, responses: responses)

        let clipboardBase64 = String(repeating: "QUJD", count: 64 * 1024)
        XCTAssertEqual(clipboardBase64.count, 256 * 1024)
        interpreter.interpret("\u{1b}]52;c;" + clipboardBase64 + "\u{7}")

        XCTAssertEqual(responses.oscCommands, ["52;c;" + clipboardBase64])
    }
}

private final class TerminalVTResponseRecorder {
    var terminalResponses: [String] = []
    /// Raw OSC command strings as the interpreter dispatched them. A payload
    /// that arrives here intact is one the parser's bound did not truncate.
    var oscCommands: [String] = []
}
