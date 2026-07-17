import XCTest
@testable import KurottyApp
import KurottyCore

final class TerminalCursorPresentationPolicyTests: XCTestCase {
    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((Int32) -> Void)?

        func start(workingDirectory: String) {}
        func write(_ text: String) {}
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    func testCursorBlinksOnlyWhenApplicationWindowAndTerminalAreFocused() {
        XCTAssertTrue(TerminalCursorPresentationPolicy.isFocusedForUser(
            isApplicationActive: true,
            isKeyWindow: true,
            isFirstResponder: true
        ))

        for state in [
            (isApplicationActive: false, isKeyWindow: true, isFirstResponder: true),
            (isApplicationActive: true, isKeyWindow: false, isFirstResponder: true),
            (isApplicationActive: true, isKeyWindow: true, isFirstResponder: false),
        ] {
            XCTAssertFalse(TerminalCursorPresentationPolicy.isFocusedForUser(
                isApplicationActive: state.isApplicationActive,
                isKeyWindow: state.isKeyWindow,
                isFirstResponder: state.isFirstResponder
            ))
        }
    }

    func testInactiveTerminalRendersCursorEvenDuringBlinkOffPhase() {
        XCTAssertTrue(TerminalCursorPresentationPolicy.shouldRenderBlinkPhase(
            isFocusedForUser: false,
            cursorBlinkOn: false,
            hasMarkedText: false
        ))
        XCTAssertFalse(TerminalCursorPresentationPolicy.shouldRenderBlinkPhase(
            isFocusedForUser: true,
            cursorBlinkOn: false,
            hasMarkedText: false
        ))
        XCTAssertTrue(TerminalCursorPresentationPolicy.shouldRenderBlinkPhase(
            isFocusedForUser: true,
            cursorBlinkOn: false,
            hasMarkedText: true
        ))
    }

    func testCursorKeepsConfiguredColorWhenItContrastsWithCellBackground() {
        let preferred = SIMD4<Float>(0.07, 0.07, 0.07, 1)
        let frame = makeFrame(defaultForeground: SIMD4<Float>(0.12, 0.13, 0.14, 1))

        XCTAssertEqual(
            TerminalCursorPresentationPolicy.visibleColor(preferred: preferred, frame: frame),
            preferred
        )
    }

    func testCursorFallsBackToHighContrastColorOnApplicationPaintedBackground() {
        let frame = makeFrame(
            defaultForeground: SIMD4<Float>(0.12, 0.13, 0.14, 1),
            cursorCellBackground: SIMD4<Float>(0.078, 0.078, 0.078, 1)
        )

        let visible = TerminalCursorPresentationPolicy.visibleColor(
            preferred: SIMD4<Float>(0.067, 0.067, 0.067, 1),
            frame: frame
        )

        XCTAssertEqual(visible, SIMD4<Float>(1, 1, 1, 1))
        XCTAssertGreaterThanOrEqual(
            TerminalCursorPresentationPolicy.contrastRatio(
                visible,
                SIMD4<Float>(0.078, 0.078, 0.078, 1)
            ),
            3
        )
    }

    private func makeFrame(
        defaultForeground: SIMD4<Float>,
        cursorCellBackground: SIMD4<Float>? = nil
    ) -> TerminalFrame {
        TerminalFrame(
            cells: [],
            backgrounds: cursorCellBackground.map {
                [TerminalBackground(column: 6, row: 19, color: $0)]
            } ?? [],
            decorations: [],
            defaultForeground: defaultForeground,
            defaultBackground: SIMD4<Float>(1, 1, 1, 1),
            dirtyRows: [19],
            dirtyRects: [],
            isFullDamage: false,
            cursorColumn: 6,
            cursorRow: 19,
            cursorBlinkOn: true,
            markedTextColumn: 6,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: 80,
            visibleRows: 24,
            cellSize: TerminalFrameSize(width: 10, height: 20),
            padding: .zero
        )
    }

    @MainActor
    func testSynchronizedTUIReenablesCursorAtFinalPosition() {
        let surface = TerminalSurfaceView(
            frame: .init(x: 0, y: 0, width: 800, height: 500),
            session: StubSession()
        )
        surface.resizeGridForTesting(columns: 80, rows: 24)

        surface.consumeTmuxRestoreOutputForTesting(Data(
            "\u{1b}[?25l\u{1b}[?2026h\u{1b}[20;7H\u{1b}[?25h\u{1b}[?2026l".utf8
        ))

        XCTAssertTrue(surface.tmuxRestoreStateForTesting.cursorVisible)
        XCTAssertEqual(surface.tmuxRestoreStateForTesting.cursorRow, 19)
        XCTAssertEqual(surface.tmuxRestoreStateForTesting.cursorColumn, 6)
    }
}
