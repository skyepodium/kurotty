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

    func testTraceSummaryReportsDroppedEventsForThatTraceOnly() {
        var ledger = TerminalEventLedger(capacity: 3)
        let first = TerminalEventTraceID("first")
        let second = TerminalEventTraceID("second")

        ledger.recordPtyRead(traceID: first, byteCount: 1)
        ledger.recordPtyRead(traceID: first, byteCount: 2)
        ledger.recordPtyRead(traceID: second, byteCount: 3)
        ledger.recordPtyRead(traceID: second, byteCount: 4)

        XCTAssertEqual(ledger.diagnostics.droppedEventCount, 1)
        XCTAssertEqual(ledger.summary(for: first).droppedEventCount, 1)
        XCTAssertEqual(ledger.summary(for: second).droppedEventCount, 0)
        XCTAssertEqual(ledger.summary(for: first).eventCount, 1)
        XCTAssertEqual(ledger.summary(for: second).eventCount, 2)
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

    func testBatchRecordingAcceptsMetadataOnlyBridgeEvents() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("batch")

        let recordedEvents = ledger.recordBatch([
            .ptyRead(traceID: traceID, byteCount: 12),
            .parserEvent(traceID: traceID, event: .printable(byteCount: 12)),
            .screenMutation(traceID: traceID, mutation: .writeCells(cellCount: 12)),
            .renderFrame(traceID: traceID, frame: .init(frameIndex: 3, dirtyRegionCount: 2, fullRedraw: false)),
        ])

        XCTAssertEqual(recordedEvents.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(recordedEvents.map(\.kind), [.ptyRead, .parserEvent, .screenMutation, .renderFrame])
        XCTAssertEqual(ledger.events, recordedEvents)
    }

    func testTraceSummaryAggregatesRetainedMetadataWithoutText() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("summary")
        let otherTraceID = TerminalEventTraceID("other")

        ledger.recordBatch([
            .ptyRead(traceID: traceID, byteCount: 8),
            .parserEvent(traceID: traceID, event: .control(kind: "BEL", byteCount: 1)),
            .parserEvent(traceID: traceID, event: .escapeSequence(kind: "CSI", byteCount: 4)),
            .screenMutation(traceID: traceID, mutation: .scroll(rowsAffected: 3)),
            .renderFrame(traceID: traceID, frame: .init(frameIndex: 4, dirtyRegionCount: 5, fullRedraw: true)),
            .ptyRead(traceID: otherTraceID, byteCount: 99),
        ])

        XCTAssertEqual(
            ledger.summary(for: traceID),
            TerminalEventLedger.TraceSummary(
                traceID: traceID,
                eventCount: 5,
                kindCounts: [
                    .ptyRead: 1,
                    .parserEvent: 2,
                    .screenMutation: 1,
                    .renderFrame: 1,
                ],
                ptyReadByteCount: 8,
                parserEventByteCount: 5,
                screenMutationCount: 1,
                renderFrameCount: 1,
                dirtyRegionCount: 5,
                fullRedrawCount: 1,
                firstSequence: 0,
                lastSequence: 4,
                droppedEventCount: 0
            )
        )

        XCTAssertFalse(ledger.summary(for: traceID).description.contains("BEL"))
        XCTAssertEqual(Set(ledger.traceSummariesByTraceID.keys), [traceID, otherTraceID])
    }
}
