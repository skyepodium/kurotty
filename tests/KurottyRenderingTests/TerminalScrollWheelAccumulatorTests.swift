import AppKit
import Foundation
import XCTest
@testable import KurottyApp

final class TerminalScrollWheelAccumulatorTests: XCTestCase {
    private final class RecordingSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((Int32) -> Void)?
        private(set) var writes: [String] = []

        func start(workingDirectory: String) {}
        func write(_ text: String) { writes.append(text) }
        func foregroundProcessName() -> String? { "test" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    func testZeroDeltaDoesNotScroll() {
        var accumulator = TerminalScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.rows(
                for: 0,
                hasPreciseScrollingDeltas: false,
                cellHeightPX: 20
            ),
            0
        )
    }

    func testPreciseInputAccumulatesAgainstCellHeight() {
        var accumulator = TerminalScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.rows(for: 8, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            0
        )
        XCTAssertEqual(
            accumulator.rows(for: 12, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            1
        )
        XCTAssertEqual(
            accumulator.rows(for: 20, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            1
        )
        XCTAssertEqual(
            accumulator.rows(for: 20, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            1
        )
    }

    func testPreciseInputPreservesSignedRemainder() {
        var accumulator = TerminalScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.rows(for: -4, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            0
        )
        XCTAssertEqual(
            accumulator.rows(for: -16, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            -1
        )
        XCTAssertEqual(
            accumulator.rows(for: 10, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            0
        )
        XCTAssertEqual(
            accumulator.rows(for: -10, hasPreciseScrollingDeltas: true, cellHeightPX: 30),
            0
        )
    }

    func testDiscreteInputScrollsTwoRowsPerWheelTickAndClearsPreciseRemainder() {
        var accumulator = TerminalScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.rows(for: 5, hasPreciseScrollingDeltas: true, cellHeightPX: 20),
            0
        )
        XCTAssertEqual(
            accumulator.rows(for: 1, hasPreciseScrollingDeltas: false, cellHeightPX: 20),
            2
        )
        XCTAssertEqual(
            accumulator.rows(for: -1, hasPreciseScrollingDeltas: false, cellHeightPX: 20),
            -2
        )
        XCTAssertEqual(
            accumulator.rows(for: 2, hasPreciseScrollingDeltas: false, cellHeightPX: 20),
            4
        )
        XCTAssertEqual(
            accumulator.rows(for: 5, hasPreciseScrollingDeltas: true, cellHeightPX: 20),
            0
        )
    }

    func testFractionalDiscreteInputStillCountsAsOneWheelTick() {
        var accumulator = TerminalScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.rows(for: 0.1, hasPreciseScrollingDeltas: false, cellHeightPX: 20),
            2
        )
        XCTAssertEqual(
            accumulator.rows(for: -0.1, hasPreciseScrollingDeltas: false, cellHeightPX: 20),
            -2
        )
    }

    @MainActor
    func testSurfaceDiscreteWheelScrollsTwoRows() throws {
        let session = RecordingSession()
        let surface = TerminalSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 120),
            session: session
        )
        let output = (0..<30).map { "row \($0)" }.joined(separator: "\r\n")
        surface.consumeTmuxRestoreOutputForTesting(Data(output.utf8))
        let scrollUp = try discreteScrollEvent(deltaY: 1)
        XCTAssertFalse(scrollUp.hasPreciseScrollingDeltas)

        surface.scrollWheel(with: scrollUp)

        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 2)
        surface.scrollWheel(with: try discreteScrollEvent(deltaY: -1))
        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)
    }

    @MainActor
    func testMouseReportingRepeatsDiscreteWheelSequenceTwoTimes() throws {
        let session = RecordingSession()
        let surface = TerminalSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 120),
            session: session
        )
        surface.consumeTmuxRestoreOutputForTesting(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))

        surface.scrollWheel(with: try discreteScrollEvent(deltaY: 1))

        let output = try XCTUnwrap(session.writes.first)
        XCTAssertEqual(session.writes.count, 1)
        XCTAssertEqual(output.components(separatedBy: "\u{1b}[<64;").count - 1, 2)
        XCTAssertEqual(surface.searchStateForTesting.scrollbackOffset, 0)
    }

    func testScrollerThumbIsSlightlyNarrowerThanItsTrack() {
        XCTAssertEqual(DesignTokens.Component.terminalScrollerWidthPX, 12)
        XCTAssertEqual(DesignTokens.Component.terminalScrollerThumbWidthPX, 9)
        XCTAssertEqual(DesignTokens.Component.terminalPreciseScrollMultiplierRATIO, 1.5)
        XCTAssertEqual(DesignTokens.Component.terminalDiscreteScrollRowsPerTick, 2)
        XCTAssertLessThan(
            DesignTokens.Component.terminalScrollerThumbWidthPX,
            DesignTokens.Component.terminalScrollerWidthPX
        )
    }

    private func discreteScrollEvent(deltaY: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        cgEvent.location = CGPoint(x: 10, y: 10)
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
