import Foundation
import XCTest
@testable import KurottyApp

final class TerminalEventLedgerTests: XCTestCase {
    func testEventsRetainOrderingAcrossPipelineStages() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("trace-1")

        ledger.recordPtyRead(traceID: traceID, data: Data([0x1B, 0x5B, 0x32, 0x4A]))
        ledger.recordParserEvent(traceID: traceID, event: .escapeSequence(kind: "CSI", byteCount: 4))
        ledger.recordScreenMutation(traceID: traceID, mutation: .eraseInDisplay(rowsAffected: 24))
        ledger.recordRenderFrame(traceID: traceID, frame: .init(frameIndex: 7, dirtyRegionCount: 1, fullRedraw: false))

        XCTAssertEqual(ledger.events.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(ledger.events.map(\.kind), [.ptyRead, .parserEvent, .screenMutation, .renderFrame])
        XCTAssertEqual(
            ledger.conciseDescription(for: traceID),
            "trace=trace-1 events=4 droppedEvents=0 [#0 ptyRead bytes=4] [#1 parserEvent escapeSequence kind=CSI bytes=4] [#2 screenMutation eraseInDisplay rows=24] [#3 renderFrame frame=7 dirtyRegions=1 fullRedraw=false]"
        )
    }

    func testEventsCanBeGroupedAndQueriedByTraceID() {
        var ledger = TerminalEventLedger(capacity: 10)
        let first = TerminalEventTraceID("first")
        let second = TerminalEventTraceID("second")

        ledger.recordPtyRead(traceID: first, byteCount: 2)
        ledger.recordPtyRead(traceID: second, byteCount: 3)
        ledger.recordRenderFrame(traceID: first, frame: .init(frameIndex: 1, dirtyRegionCount: 2, fullRedraw: true))

        XCTAssertEqual(ledger.events(for: first).map(\.kind), [.ptyRead, .renderFrame])
        XCTAssertEqual(ledger.events(for: second).map(\.kind), [.ptyRead])
        XCTAssertEqual(Set(ledger.eventsByTraceID.keys), [first, second])
    }

    func testBoundedRetentionDropsOldestEventsAndReportsDiagnostics() {
        var ledger = TerminalEventLedger(capacity: 2)
        let traceID = TerminalEventTraceID("bounded")

        ledger.recordPtyRead(traceID: traceID, byteCount: 1)
        ledger.recordParserEvent(traceID: traceID, event: .printable(byteCount: 1))
        ledger.recordRenderFrame(traceID: traceID, frame: .init(frameIndex: 9, dirtyRegionCount: 3, fullRedraw: false))

        XCTAssertEqual(ledger.events.map(\.sequence), [1, 2])
        XCTAssertEqual(ledger.diagnostics.capacity, 2)
        XCTAssertEqual(ledger.diagnostics.retainedEventCount, 2)
        XCTAssertEqual(ledger.diagnostics.droppedEventCount, 1)
        XCTAssertEqual(ledger.diagnostics.firstRetainedSequence, 1)
        XCTAssertEqual(ledger.diagnostics.nextSequence, 3)
        XCTAssertEqual(ledger.diagnostics.description, "capacity=2 retainedEvents=2 droppedEvents=1 firstRetainedSequence=1 nextSequence=3")
    }

    func testLedgerDoesNotStoreRawBytesOrTerminalText() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("safe")
        let secretBytes = Data("secret-token".utf8)

        ledger.recordPtyRead(traceID: traceID, data: secretBytes)
        ledger.recordParserEvent(traceID: traceID, event: .printable(byteCount: secretBytes.count))
        ledger.recordScreenMutation(traceID: traceID, mutation: .writeCells(cellCount: 12))

        let mirrorText = String(describing: ledger)
        let eventText = ledger.events.map(String.init(describing:)).joined(separator: "\n")
        let description = ledger.conciseDescription(for: traceID)

        XCTAssertFalse(mirrorText.contains("secret-token"))
        XCTAssertFalse(eventText.contains("secret-token"))
        XCTAssertFalse(description.contains("secret-token"))
        XCTAssertTrue(description.contains("bytes=12"))
        XCTAssertTrue(description.contains("cells=12"))
    }
}
