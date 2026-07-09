import XCTest
@testable import KurottyApp

final class TerminalMouseReportingTests: XCTestCase {
    func testMouseReportingStateTracksDECPrivateModes() {
        var state = TerminalMouseReportingState()

        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.trackingMode, .none)

        state.set(decPrivateMode: 1000, enabled: true)
        XCTAssertTrue(state.isEnabled)
        XCTAssertEqual(state.trackingMode, .normal)

        state.set(decPrivateMode: 1002, enabled: true)
        XCTAssertEqual(state.trackingMode, .buttonMotion)

        state.set(decPrivateMode: 1003, enabled: true)
        XCTAssertEqual(state.trackingMode, .anyMotion)

        state.set(decPrivateMode: 1006, enabled: true)
        XCTAssertTrue(state.usesSGRExtendedCoordinates)

        state.reset()
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.usesSGRExtendedCoordinates)
    }

    func testSGRMouseSequencesUseOneBasedVisibleCoordinates() {
        var state = TerminalMouseReportingState()
        state.set(decPrivateMode: 1000, enabled: true)
        state.set(decPrivateMode: 1006, enabled: true)

        XCTAssertEqual(
            TerminalMouseEventEncoder.sequence(
                for: .press(.left),
                column: 11,
                row: 4,
                modifiers: [],
                reportingState: state
            ),
            "\u{1b}[<0;12;5M"
        )
        XCTAssertEqual(
            TerminalMouseEventEncoder.sequence(
                for: .release(.left),
                column: 11,
                row: 4,
                modifiers: [],
                reportingState: state
            ),
            "\u{1b}[<0;12;5m"
        )
    }

    func testMouseMotionRequiresMotionTrackingModes() {
        var state = TerminalMouseReportingState()
        state.set(decPrivateMode: 1000, enabled: true)
        state.set(decPrivateMode: 1006, enabled: true)

        XCTAssertNil(TerminalMouseEventEncoder.sequence(
            for: .drag(.left),
            column: 0,
            row: 0,
            modifiers: [],
            reportingState: state
        ))

        state.set(decPrivateMode: 1002, enabled: true)
        XCTAssertEqual(
            TerminalMouseEventEncoder.sequence(
                for: .drag(.left),
                column: 0,
                row: 0,
                modifiers: [],
                reportingState: state
            ),
            "\u{1b}[<32;1;1M"
        )

        XCTAssertNil(TerminalMouseEventEncoder.sequence(
            for: .move,
            column: 0,
            row: 0,
            modifiers: [],
            reportingState: state
        ))

        state.set(decPrivateMode: 1003, enabled: true)
        XCTAssertEqual(
            TerminalMouseEventEncoder.sequence(
                for: .move,
                column: 0,
                row: 0,
                modifiers: [],
                reportingState: state
            ),
            "\u{1b}[<35;1;1M"
        )
    }

    func testWheelAndModifiersEncodeButtonCodeOffsets() {
        var state = TerminalMouseReportingState()
        state.set(decPrivateMode: 1000, enabled: true)
        state.set(decPrivateMode: 1006, enabled: true)

        XCTAssertEqual(
            TerminalMouseEventEncoder.sequence(
                for: .wheelUp,
                column: 2,
                row: 3,
                modifiers: [.option, .control],
                reportingState: state
            ),
            "\u{1b}[<88;3;4M"
        )
        XCTAssertEqual(
            TerminalMouseEventEncoder.sequence(
                for: .wheelDown,
                column: 2,
                row: 3,
                modifiers: [],
                reportingState: state
            ),
            "\u{1b}[<65;3;4M"
        )
    }
}
