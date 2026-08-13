import KurottyCore
import XCTest
@testable import KurottyApp

/// What a hostile or broken child process can make the parser allocate, and how
/// the parser gets out of it.
///
/// Every case here feeds its payload the way a PTY does — split across several
/// `interpret` calls, so the bound has to survive a sequence that spans reads —
/// and then asserts the three things a bound is worth having for: nothing the
/// discarded sequence carried reaches the screen, the parser is between
/// sequences again, and the next legitimate sequence still applies. The
/// `\e[99999m` abort survived a full test suite because no test could observe
/// the parser's resource use, so these assert behaviour and never source text.
final class TerminalParserResourceLimitTests: XCTestCase {
    // MARK: - Fixtures

    /// Payload feed size. Nothing protocol-specific: it only keeps the tests
    /// from building one multi-megabyte String per call.
    private static let payloadChunkBytes = 64 * 1024

    @MainActor
    private func makeInterpreter(
        rows: Int,
        columns: Int,
        recorder: TerminalParserLimitRecorder? = nil
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.screen.resize(rows: rows, columns: columns)
        interpreter.lastSentSize = TerminalSize(columns: columns, rows: rows)
        interpreter.resetScrollRegion()
        if let recorder {
            interpreter.host = TerminalOutputInterpreterHost(
                sendTerminalResponse: { _ in },
                respondToOscQuery: { _ in },
                dispatchTerminalIntegrationOsc: {
                    recorder.oscCommands.append($0)
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

    /// Feeds `count` copies of `filler` the way a PTY read loop would, in
    /// chunks rather than one allocation.
    @MainActor
    private func feedPayload(
        _ interpreter: TerminalOutputInterpreter,
        filler: String,
        count: Int
    ) {
        var remaining = count
        let chunk = String(repeating: filler, count: Self.payloadChunkBytes)
        while remaining > 0 {
            let size = min(remaining, Self.payloadChunkBytes)
            interpreter.interpret(size == Self.payloadChunkBytes ? chunk : String(repeating: filler, count: size))
            remaining -= size
        }
    }

    @MainActor
    private func screenText(_ interpreter: TerminalOutputInterpreter) -> String {
        interpreter.screen.cells
            .map { String($0.map(\.character)) }
            .joined()
    }

    @MainActor
    private func assertScreenIsBlank(
        _ interpreter: TerminalOutputInterpreter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let painted = screenText(interpreter).filter { $0 != " " }
        XCTAssertEqual(painted, "", "discarded payload reached the screen", file: file, line: line)
    }

    /// The recovery every case shares: after the bound fires, an ordinary
    /// sequence has to parse and apply as if nothing had happened.
    @MainActor
    private func assertRecoveredSequenceApplies(
        _ interpreter: TerminalOutputInterpreter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(interpreter.isParsingBetweenSequences, "parser is still mid-sequence", file: file, line: line)
        interpreter.interpret("\u{1b}[31mred")
        let row = String(interpreter.screen.cells[interpreter.cursorRow].map(\.character))
        XCTAssertEqual(row.prefix(3), "red", file: file, line: line)
        XCTAssertEqual(
            interpreter.screen.cells[interpreter.cursorRow][0].style.foreground,
            DesignTokens.Color.ansiNormal[1],
            file: file,
            line: line
        )
    }

    // MARK: - String controls (DCS, SOS, PM, APC)

    /// A DCS whose `ESC \` never arrives used to consume the stream for the
    /// rest of the session: nothing after it could be parsed, and the pane
    /// looked frozen. Past the bound the sequence is abandoned instead.
    @MainActor
    func testUnterminatedDCSPayloadStopsSwallowingTheStreamAtItsBound() {
        let interpreter = makeInterpreter(rows: 4, columns: 20)

        interpreter.interpret("\u{1b}P")
        feedPayload(
            interpreter,
            filler: "x",
            count: AppConstants.Terminal.maximumStringControlScalarCount + 1
        )

        assertScreenIsBlank(interpreter)
        assertRecoveredSequenceApplies(interpreter)
    }

    /// The same for APC, the envelope the Kitty graphics protocol uses. Kitty
    /// requires clients to chunk at 4096 bytes per escape, so a payload this
    /// size is not a client that needs its image drawn.
    @MainActor
    func testUnterminatedAPCPayloadStopsSwallowingTheStreamAtItsBound() {
        let interpreter = makeInterpreter(rows: 4, columns: 20)

        // The graphics key that follows `ESC _` is payload too, so it counts
        // against the bound like the rest of it.
        interpreter.interpret("\u{1b}_G")
        feedPayload(
            interpreter,
            filler: "y",
            count: AppConstants.Terminal.maximumStringControlScalarCount + 1 - "G".count
        )

        assertScreenIsBlank(interpreter)
        assertRecoveredSequenceApplies(interpreter)
    }

    /// The other half of the bound: a payload that stays inside it is still
    /// consumed whole, terminator and all. tmux's DCS passthrough wraps
    /// arbitrary inner sequences, and a bound that abandoned those mid-payload
    /// would spray them onto the screen — a worse bug than the one it fixes.
    @MainActor
    func testStringControlWithinItsBoundIsStillConsumedThroughItsTerminator() {
        let interpreter = makeInterpreter(rows: 4, columns: 20)

        interpreter.interpret("\u{1b}Ptmux;")
        feedPayload(
            interpreter,
            filler: "x",
            count: AppConstants.Terminal.maximumStringControlScalarCount - "tmux;".count
        )
        XCTAssertFalse(interpreter.isParsingBetweenSequences)

        interpreter.interpret("\u{1b}\\")
        assertScreenIsBlank(interpreter)
        assertRecoveredSequenceApplies(interpreter)
    }

    // MARK: - OSC

    /// An oversized OSC split across reads: the title must not be applied
    /// truncated, no OSC must be dispatched, and the parser must still find its
    /// way back at the string terminator.
    @MainActor
    func testOversizedOSCPayloadSplitAcrossReadsIsDiscardedWhole() {
        let recorder = TerminalParserLimitRecorder()
        let interpreter = makeInterpreter(rows: 4, columns: 20, recorder: recorder)
        let originalTitle = interpreter.terminalTitle

        interpreter.interpret("\u{1b}]0;")
        feedPayload(
            interpreter,
            filler: "t",
            count: AppConstants.Terminal.maximumStringPayloadBytes + 1
        )
        interpreter.interpret("\u{1b}\\")

        XCTAssertEqual(interpreter.terminalTitle, originalTitle)
        XCTAssertEqual(recorder.oscCommands, [])
        assertScreenIsBlank(interpreter)
        assertRecoveredSequenceApplies(interpreter)
    }

    /// The bound has to sit above what programs legitimately send. An OSC 52
    /// clipboard write of a 192 KiB selection — 256 KiB of base64, arriving in
    /// as many reads as the PTY feels like — must reach the dispatcher intact.
    @MainActor
    func testLargeOSC52ClipboardWriteSplitAcrossReadsSurvivesTheBound() {
        let recorder = TerminalParserLimitRecorder()
        let interpreter = makeInterpreter(rows: 4, columns: 20, recorder: recorder)
        let base64GroupCount = 64 * 1024

        interpreter.interpret("\u{1b}]52;c;")
        feedPayload(interpreter, filler: "QUJD", count: base64GroupCount)
        interpreter.interpret("\u{7}")

        XCTAssertEqual(
            recorder.oscCommands,
            ["52;c;" + String(repeating: "QUJD", count: base64GroupCount)]
        )
    }

    // MARK: - CSI

    /// An oversized CSI split across reads. Executing `CSI <first 256 bytes> H`
    /// would move the cursor somewhere the program never asked for, so the
    /// parameters are dropped and the sequence with them.
    @MainActor
    func testOversizedCSIParametersSplitAcrossReadsAreDiscardedRatherThanExecuted() {
        let interpreter = makeInterpreter(rows: 4, columns: 20)

        interpreter.interpret("\u{1b}[")
        feedPayload(
            interpreter,
            filler: "1",
            count: AppConstants.Terminal.maximumCsiParameterBytes + 1
        )
        interpreter.interpret(";5H")

        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 0)
        assertScreenIsBlank(interpreter)
        assertRecoveredSequenceApplies(interpreter)
    }

    // MARK: - Grapheme clusters

    /// Combining marks have no natural end. `printf 'a'` followed by an
    /// endless run of U+0301 kept extending one cell's `Character`, which is
    /// one heap string, and the shaper re-laid the whole cluster out on every frame.
    @MainActor
    func testCombiningMarkFloodIsBoundedToOneCell() {
        let interpreter = makeInterpreter(rows: 2, columns: 10)
        let markCount = 5_000

        interpreter.interpret("a")
        for _ in 0..<markCount {
            interpreter.interpret("\u{0301}")
        }

        XCTAssertEqual(
            interpreter.screen.cells[0][0].character.unicodeScalars.count,
            AppConstants.Terminal.maximumCellGraphemeScalarCount
        )
        // The marks are zero width, so the flood must not have advanced the
        // cursor or spilled into the next cell either.
        XCTAssertEqual(interpreter.cursorColumn, 1)
        XCTAssertEqual(interpreter.screen.cells[0][1].character, " ")
    }

    /// The same flood arriving inside a single read is a single grapheme
    /// cluster by the time Swift hands it over, so the bound has to apply to
    /// the printable path as well as to marks arriving one at a time.
    @MainActor
    func testOversizedGraphemeClusterInOneReadIsBoundedToOneCell() {
        let interpreter = makeInterpreter(rows: 2, columns: 10)

        interpreter.interpret("a" + String(repeating: "\u{0301}", count: 5_000))

        XCTAssertEqual(
            interpreter.screen.cells[0][0].character.unicodeScalars.count,
            AppConstants.Terminal.maximumCellGraphemeScalarCount
        )
        XCTAssertEqual(interpreter.cursorColumn, 1)
    }

    /// The other half of the grapheme bound. Real text stacks marks too, and
    /// none of it comes near the Stream-Safe limit the bound is drawn from.
    @MainActor
    func testRealCombiningSequencesAreUnaffectedByTheBound() {
        let interpreter = makeInterpreter(rows: 2, columns: 10)

        // Latin acute, a Thai vowel + tone stack, and a Devanagari cluster.
        interpreter.interpret("e\u{0301}")
        interpreter.interpret("\u{0e01}\u{0e35}\u{0e49}")
        interpreter.interpret("\u{0928}\u{093f}")

        XCTAssertEqual(interpreter.screen.cells[0][0].character, "é")
        XCTAssertEqual(interpreter.screen.cells[0][1].character, "\u{0e01}\u{0e35}\u{0e49}")
        XCTAssertEqual(interpreter.screen.cells[0][2].character, "\u{0928}\u{093f}")
    }
}

private final class TerminalParserLimitRecorder {
    /// Raw OSC command strings as the interpreter dispatched them. A payload
    /// that arrives here intact is one the bound did not truncate; a discarded
    /// payload must not arrive at all.
    var oscCommands: [String] = []
}
