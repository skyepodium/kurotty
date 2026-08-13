import AppKit
import Foundation
import Metal
import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// DECSCUSR (`CSI Ps SP q`): the parameter table, what an undefined parameter
/// does, what a reset restores, what the three shapes draw, and how the shape
/// survives a tmux reattach.
///
/// Every parser assertion feeds real bytes to `TerminalOutputInterpreter`, so a
/// sequence that stops being recognised fails here rather than in a rename.
@MainActor
final class TerminalCursorStyleTests: XCTestCase {
    private enum Fixture {
        static let rows = 6
        static let columns = 12
        static let cursorRow = 2
        static let cursorColumn = 3
        static let cellSize = TerminalFrameSize(width: 10, height: 20)
        static let viewSize = NSRect(x: 0, y: 0, width: 200, height: 120)
        /// Parameters DECSCUSR does not define. `7` is one past the table and
        /// `2026` is a DEC private mode number that shares this final byte's
        /// neighbourhood in real streams.
        static let undefinedParameters = [7, 8, 99, 2026]
    }

    private func makeInterpreter() -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.screen = TerminalScreen(rows: Fixture.rows, columns: Fixture.columns)
        interpreter.scrollRegionBottom = Fixture.rows - 1
        return interpreter
    }

    // MARK: - Parameter table

    func testEveryDefinedParameterSelectsItsShapeAndBlinkState() {
        let expected: [(parameter: Int, style: TerminalCursorStyle)] = [
            (1, TerminalCursorStyle(shape: .block, blinks: true)),
            (2, TerminalCursorStyle(shape: .block, blinks: false)),
            (3, TerminalCursorStyle(shape: .underline, blinks: true)),
            (4, TerminalCursorStyle(shape: .underline, blinks: false)),
            (5, TerminalCursorStyle(shape: .bar, blinks: true)),
            (6, TerminalCursorStyle(shape: .bar, blinks: false)),
        ]

        for (parameter, style) in expected {
            let interpreter = makeInterpreter()
            interpreter.interpret("\u{1b}[\(parameter) q")
            XCTAssertEqual(interpreter.cursorStyle, style, "Ps=\(parameter)")
        }
    }

    /// `CSI 0 SP q` and a bare `CSI SP q` both mean "the terminal's own
    /// default", which is where a program resetting the cursor expects to land.
    func testDefaultParameterAndOmittedParameterBothRestoreTheDefaultStyle() {
        for sequence in ["\u{1b}[0 q", "\u{1b}[ q"] {
            let interpreter = makeInterpreter()
            interpreter.interpret("\u{1b}[2 q")
            XCTAssertEqual(interpreter.cursorStyle.shape, .block, sequence)

            interpreter.interpret(sequence)

            XCTAssertEqual(interpreter.cursorStyle, .default, sequence)
        }
    }

    /// An out-of-range `Ps` leaves the cursor exactly as it was. Clamping it to
    /// the nearest shape would let a malformed sequence silently repaint the
    /// cursor, and reading past the table would crash.
    func testUndefinedParametersLeaveTheCursorStyleUntouched() {
        for parameter in Fixture.undefinedParameters {
            let interpreter = makeInterpreter()
            interpreter.interpret("\u{1b}[4 q")

            interpreter.interpret("\u{1b}[\(parameter) q")

            XCTAssertEqual(
                interpreter.cursorStyle,
                TerminalCursorStyle(shape: .underline, blinks: false),
                "Ps=\(parameter)"
            )
        }
    }

    /// The space intermediate is the whole difference between DECSCUSR and the
    /// other sequences that end in `q`: DECSCA is `CSI Ps " q`, XTVERSION is
    /// `CSI > q`, and DECLL is `CSI Ps q`. None of them touch the cursor shape.
    func testSequencesEndingInQWithoutTheSpaceIntermediateAreNotDecscusr() {
        for sequence in ["\u{1b}[2q", "\u{1b}[>q", "\u{1b}[1\"q", "\u{1b}[?2 q"] {
            let interpreter = makeInterpreter()
            interpreter.interpret("\u{1b}[3 q")

            interpreter.interpret(sequence)

            XCTAssertEqual(
                interpreter.cursorStyle,
                TerminalCursorStyle(shape: .underline, blinks: true),
                sequence
            )
        }
    }

    func testDecscusrDoesNotDisturbTheCursorPositionOrTheScreen() {
        let interpreter = makeInterpreter()
        interpreter.interpret("ab")

        interpreter.interpret("\u{1b}[6 q")

        XCTAssertEqual(interpreter.cursorRow, 0)
        XCTAssertEqual(interpreter.cursorColumn, 2)
        XCTAssertEqual(String(interpreter.screen.cells[0].prefix(2).map(\.character)), "ab")
    }

    // MARK: - Reset

    /// RIS is a power-on reset, so the shape a TUI left behind must not outlive
    /// the program that set it. `reset` at a wedged prompt depends on this.
    func testFullResetRestoresTheDefaultCursorStyle() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[2 q")
        XCTAssertNotEqual(interpreter.cursorStyle, .default)

        interpreter.interpret("\u{1b}c")

        XCTAssertEqual(interpreter.cursorStyle, .default)
    }

    /// Switching screens is not a reset. `vim` sets a bar for insert mode on
    /// the alternate screen and restores the shape itself on the way out.
    func testAlternateScreenSwitchesKeepTheSelectedCursorStyle() {
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[5 q")

        interpreter.interpret("\u{1b}[?1049h")
        XCTAssertEqual(interpreter.cursorStyle, TerminalCursorStyle(shape: .bar, blinks: true))

        interpreter.interpret("\u{1b}[?1049l")
        XCTAssertEqual(interpreter.cursorStyle, TerminalCursorStyle(shape: .bar, blinks: true))
    }

    // MARK: - Blink phase

    /// A steady style ignores the blink phase outright rather than waiting for
    /// the shared timer to come back around to its on phase.
    func testSteadyStylesRenderDuringTheBlinkOffPhase() {
        XCTAssertTrue(TerminalCursorPresentationPolicy.shouldRenderBlinkPhase(
            isFocusedForUser: true,
            cursorStyleBlinks: false,
            cursorBlinkOn: false,
            hasMarkedText: false
        ))
        XCTAssertFalse(TerminalCursorPresentationPolicy.shouldRenderBlinkPhase(
            isFocusedForUser: true,
            cursorStyleBlinks: true,
            cursorBlinkOn: false,
            hasMarkedText: false
        ))
    }

    // MARK: - Geometry

    /// The three shapes are drawn from one cell rect: the block is the cell,
    /// the underline is a rule on its bottom edge, and the bar is a rule on its
    /// leading edge. Asserting the relationships keeps this independent of the
    /// backing scale the test host happens to have.
    func testEachShapeDrawsItsOwnRegionOfTheCursorCell() throws {
        let block = try cursorRect(for: TerminalCursorStyle(shape: .block, blinks: false))
        let underline = try cursorRect(for: TerminalCursorStyle(shape: .underline, blinks: false))
        let bar = try cursorRect(for: TerminalCursorStyle(shape: .bar, blinks: false))

        XCTAssertEqual(block.width, CGFloat(Fixture.cellSize.width), accuracy: 0.001)
        XCTAssertGreaterThan(block.height, 0)

        XCTAssertEqual(underline.minX, block.minX, accuracy: 0.001)
        XCTAssertEqual(underline.minY, block.minY, accuracy: 0.001)
        XCTAssertEqual(underline.width, block.width, accuracy: 0.001)
        XCTAssertLessThan(underline.height, block.height)

        XCTAssertEqual(bar.minX, block.minX, accuracy: 0.001)
        XCTAssertEqual(bar.minY, block.minY, accuracy: 0.001)
        XCTAssertEqual(bar.height, block.height, accuracy: 0.001)
        XCTAssertLessThan(bar.width, block.width)
    }

    /// The bar is what Kurotty drew before DECSCUSR existed, so the default
    /// must keep drawing exactly that rect.
    func testTheDefaultStyleDrawsTheBarKurottyAlreadyDrew() throws {
        let `default` = try cursorRect(for: .default)
        let bar = try cursorRect(for: TerminalCursorStyle(shape: .bar, blinks: true))

        XCTAssertEqual(`default`, bar)
    }

    // MARK: - tmux reattach

    /// tmux keeps the shape out of `capture-pane`, so the reattach replay has
    /// to restate it. The replay is fed back through an interpreter rather than
    /// matched as text: what matters is the shape the pane ends up in.
    func testTmuxSnapshotReplayRestoresThePanesCursorStyle() throws {
        let cases: [(shape: String, blinking: String, expected: TerminalCursorStyle)] = [
            ("block", "1", TerminalCursorStyle(shape: .block, blinks: true)),
            ("block", "0", TerminalCursorStyle(shape: .block, blinks: false)),
            ("underline", "1", TerminalCursorStyle(shape: .underline, blinks: true)),
            ("bar", "0", TerminalCursorStyle(shape: .bar, blinks: false)),
            ("default", "0", .default),
        ]

        for testCase in cases {
            let state = try XCTUnwrap(TmuxPaneTerminalState.parse(
                paneStateLine(cursorShape: testCase.shape, cursorBlinking: testCase.blinking),
                expectedPaneID: "%3"
            ))
            let snapshot = TmuxPaneSnapshot(
                currentScreen: Data("hello".utf8),
                alternateScreen: Data(),
                terminalState: state,
                pendingOutput: Data(),
                byteLimit: 8_192
            )

            let interpreter = makeInterpreter()
            interpreter.interpret("\u{1b}[2 q")
            interpreter.interpret(String(decoding: snapshot.replayData, as: UTF8.self))

            XCTAssertEqual(interpreter.cursorStyle, testCase.expected, testCase.shape)
        }
    }

    /// A tmux too old to publish `cursor_shape` reports nothing at all, which
    /// must land on the default rather than on a guessed shape.
    func testTmuxPaneStateWithoutCursorShapeFieldsFallsBackToTheDefault() throws {
        let fields = paneStateLine(cursorShape: "block", cursorBlinking: "1")
            .split(separator: "\t")
            .filter { !$0.hasPrefix("cursor_shape=") && !$0.hasPrefix("cursor_blinking=") }
            .joined(separator: "\t")

        let state = try XCTUnwrap(TmuxPaneTerminalState.parse(fields, expectedPaneID: "%3"))

        XCTAssertNil(state.cursorStyle)

        let snapshot = TmuxPaneSnapshot(
            currentScreen: Data(),
            alternateScreen: Data(),
            terminalState: state,
            pendingOutput: Data(),
            byteLimit: 8_192
        )
        let interpreter = makeInterpreter()
        interpreter.interpret("\u{1b}[4 q")
        interpreter.interpret(String(decoding: snapshot.replayData, as: UTF8.self))

        XCTAssertEqual(interpreter.cursorStyle, .default)
    }

    /// The pane-state query has to ask for the two formats the replay reads.
    func testPaneStateQueryAsksTmuxForTheCursorShapeAndBlinkFormats() {
        let command = String(decoding: TmuxCommandEncoder.listPaneState("%3"), as: UTF8.self)

        XCTAssertTrue(command.contains("cursor_shape=#{cursor_shape}"), command)
        XCTAssertTrue(command.contains("cursor_blinking=#{cursor_blinking}"), command)
    }

    // MARK: - Round trip

    func testEveryStyleRoundTripsThroughItsDecscusrParameter() {
        for shape in [TerminalCursorStyle.Shape.block, .underline, .bar] {
            for blinks in [true, false] {
                let style = TerminalCursorStyle(shape: shape, blinks: blinks)
                XCTAssertEqual(TerminalCursorStyle.decscusr(parameter: style.decscusrParameter), style)
            }
        }
    }

    // MARK: - Helpers

    private func cursorRect(for style: TerminalCursorStyle) throws -> CGRect {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is not available")
        }
        let view = TerminalMetalView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.frame = Fixture.viewSize
        view.update(frame: makeFrame(cursorStyle: style))
        return view.cursorRectForTesting(column: Fixture.cursorColumn, row: Fixture.cursorRow)
    }

    private func makeFrame(cursorStyle: TerminalCursorStyle) -> TerminalFrame {
        TerminalFrame(
            cells: [],
            backgrounds: [],
            decorations: [],
            defaultForeground: SIMD4<Float>(1, 1, 1, 1),
            defaultBackground: SIMD4<Float>(0, 0, 0, 1),
            dirtyRows: [],
            dirtyRects: [],
            isFullDamage: true,
            cursorColumn: Fixture.cursorColumn,
            cursorRow: Fixture.cursorRow,
            cursorBlinkOn: true,
            cursorStyle: cursorStyle,
            markedTextColumn: Fixture.cursorColumn,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: Fixture.columns,
            visibleRows: Fixture.rows,
            cellSize: Fixture.cellSize,
            padding: .zero
        )
    }

    private func paneStateLine(cursorShape: String, cursorBlinking: String) -> String {
        [
            "pane_id=%3", "pane_width=\(Fixture.columns)", "pane_height=\(Fixture.rows)",
            "alternate_on=0", "cursor_x=0", "cursor_y=0",
            "scroll_region_upper=0", "scroll_region_lower=\(Fixture.rows - 1)",
            "pane_tabs=8", "cursor_flag=1",
            "cursor_shape=\(cursorShape)", "cursor_blinking=\(cursorBlinking)",
            "insert_flag=0", "origin_flag=0", "keypad_cursor_flag=0", "keypad_flag=0",
            "wrap_flag=1", "mouse_standard_flag=0", "mouse_button_flag=0", "mouse_any_flag=0",
            "mouse_utf8_flag=0", "mouse_sgr_flag=0", "bracket_paste_flag=0", "pane_key_mode=",
            "extended_keys_format=xterm", "session_attached=1",
        ].joined(separator: "\t")
    }
}
