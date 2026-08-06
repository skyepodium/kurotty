import XCTest
@testable import KurottyApp

final class TerminalAlternateScrollTests: XCTestCase {
    private func context(
        isAlternateScreenActive: Bool = true,
        isAlternateScrollEnabled: Bool = true,
        isMouseReportingEnabled: Bool = false,
        applicationCursorKeysEnabled: Bool = false,
        isShiftHeld: Bool = false
    ) -> TerminalAlternateScroll.Context {
        TerminalAlternateScroll.Context(
            isAlternateScreenActive: isAlternateScreenActive,
            isAlternateScrollEnabled: isAlternateScrollEnabled,
            isMouseReportingEnabled: isMouseReportingEnabled,
            applicationCursorKeysEnabled: applicationCursorKeysEnabled,
            isShiftHeld: isShiftHeld
        )
    }

    func testWheelBecomesOneCursorKeyPerScrolledRow() {
        XCTAssertEqual(
            TerminalAlternateScroll.keySequence(rowDelta: 3, context: context()),
            "\u{1b}[A\u{1b}[A\u{1b}[A"
        )
        XCTAssertEqual(
            TerminalAlternateScroll.keySequence(rowDelta: -2, context: context()),
            "\u{1b}[B\u{1b}[B"
        )
    }

    func testApplicationCursorKeysModeSwitchesToTheSS3Form() {
        XCTAssertEqual(
            TerminalAlternateScroll.keySequence(
                rowDelta: 1,
                context: context(applicationCursorKeysEnabled: true)
            ),
            "\u{1b}OA"
        )
        XCTAssertEqual(
            TerminalAlternateScroll.keySequence(
                rowDelta: -1,
                context: context(applicationCursorKeysEnabled: true)
            ),
            "\u{1b}OB"
        )
    }

    func testNothingIsSentOnTheNormalScreen() {
        XCTAssertFalse(TerminalAlternateScroll.claimsWheel(in: context(isAlternateScreenActive: false)))
        XCTAssertNil(
            TerminalAlternateScroll.keySequence(rowDelta: 3, context: context(isAlternateScreenActive: false))
        )
    }

    func testMouseReportingKeepsTheWheelSoAppsThatTrackItAreNotDoubleFed() {
        XCTAssertFalse(TerminalAlternateScroll.claimsWheel(in: context(isMouseReportingEnabled: true)))
        XCTAssertNil(
            TerminalAlternateScroll.keySequence(rowDelta: 3, context: context(isMouseReportingEnabled: true))
        )
    }

    func testDisablingMode1007TurnsTheTranslationOff() {
        XCTAssertFalse(TerminalAlternateScroll.claimsWheel(in: context(isAlternateScrollEnabled: false)))
        XCTAssertNil(
            TerminalAlternateScroll.keySequence(rowDelta: 3, context: context(isAlternateScrollEnabled: false))
        )
    }

    func testShiftReleasesTheWheelBackToTheTerminalsOwnScrolling() {
        XCTAssertFalse(TerminalAlternateScroll.claimsWheel(in: context(isShiftHeld: true)))
        XCTAssertNil(TerminalAlternateScroll.keySequence(rowDelta: 3, context: context(isShiftHeld: true)))
    }

    func testASubRowGestureIsStillClaimedButSendsNothing() {
        XCTAssertTrue(TerminalAlternateScroll.claimsWheel(in: context()))
        XCTAssertNil(TerminalAlternateScroll.keySequence(rowDelta: 0, context: context()))
    }

    func testMode1007IsEnabledByDefaultAndSurvivesAReset() {
        var state = TerminalMouseReportingState()
        XCTAssertTrue(state.alternateScrollEnabled)

        state.set(decPrivateMode: 1007, enabled: false)
        XCTAssertFalse(state.alternateScrollEnabled)

        state.set(decPrivateMode: 1007, enabled: true)
        XCTAssertTrue(state.alternateScrollEnabled)

        state.set(decPrivateMode: 1007, enabled: false)
        state.reset()
        XCTAssertTrue(state.alternateScrollEnabled, "a reset forgets the app's choice, it does not disable the wheel")
    }

    func testMode1007DoesNotTurnOnMouseReporting() {
        var state = TerminalMouseReportingState()
        state.set(decPrivateMode: 1007, enabled: true)

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.trackingMode, TerminalMouseTrackingMode.none)
    }

    @MainActor
    func testTheInterpreterRoutesMode1007AndTheAlternateScreenIntoTheWheelContext() {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: DesignTokens.Color.ansiNormal + DesignTokens.Color.ansiBright,
            maxScrollbackRows: 1_000
        )

        XCTAssertFalse(interpreter.isUsingAlternateScreen)
        XCTAssertTrue(interpreter.mouseReportingState.alternateScrollEnabled)

        interpreter.interpret("\u{1b}[?1049h")
        XCTAssertTrue(interpreter.isUsingAlternateScreen)
        XCTAssertTrue(TerminalAlternateScroll.claimsWheel(in: context(
            isAlternateScreenActive: interpreter.isUsingAlternateScreen,
            isAlternateScrollEnabled: interpreter.mouseReportingState.alternateScrollEnabled
        )))

        interpreter.interpret("\u{1b}[?1007l")
        XCTAssertFalse(interpreter.mouseReportingState.alternateScrollEnabled)
        XCTAssertFalse(TerminalAlternateScroll.claimsWheel(in: context(
            isAlternateScreenActive: interpreter.isUsingAlternateScreen,
            isAlternateScrollEnabled: interpreter.mouseReportingState.alternateScrollEnabled
        )))

        interpreter.interpret("\u{1b}[?1007h")
        XCTAssertTrue(interpreter.mouseReportingState.alternateScrollEnabled)
    }
}
