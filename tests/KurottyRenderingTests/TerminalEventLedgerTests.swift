import Foundation
import XCTest
@testable import KurottyCore
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

    func testTimelineSummariesExposeDeterministicLiveSummaryWithoutPayloadText() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("live-summary")
        let otherTraceID = TerminalEventTraceID("other-live-summary")
        let secretBytes = Data("secret-token".utf8)

        ledger.recordPtyRead(traceID: traceID, data: secretBytes)
        ledger.recordParserEvent(traceID: traceID, event: .printable(byteCount: secretBytes.count))
        ledger.recordScreenMutation(traceID: traceID, mutation: .writeCells(cellCount: 12))
        ledger.recordRenderFrame(traceID: traceID, frame: .init(frameIndex: 5, dirtyRegionCount: 2, fullRedraw: false))
        ledger.recordPtyRead(traceID: otherTraceID, byteCount: 3)

        let summary = ledger.timelineSummary(for: traceID)
        let summaries = ledger.timelineSummariesByTraceID

        XCTAssertEqual(summary.traceID, traceID)
        XCTAssertEqual(summary.stagePath, "ptyRead>parserEvent>screenMutation>renderFrame")
        XCTAssertTrue(summary.hasCompleteRenderPath)
        XCTAssertEqual(summary.ptyReadByteCount, secretBytes.count)
        XCTAssertEqual(summary.parserEventByteCount, secretBytes.count)
        XCTAssertEqual(summary.screenMutationCount, 1)
        XCTAssertEqual(summary.renderFrameCount, 1)
        XCTAssertEqual(summary.dirtyRegionCount, 2)
        XCTAssertEqual(Set(summaries.keys), [traceID, otherTraceID])
        XCTAssertEqual(summaries[traceID], summary)
        XCTAssertFalse(summary.description.contains("secret-token"))
    }

    func testLivePtyReadMetadataIsWiredIntoRuntimeLedgerWithoutRawPayload() throws {
        let sessionSource = try sourceFile("Sources/KurottyApp/TerminalSession.swift")
        let shellSource = try sourceFile("Sources/KurottyApp/ShellSession.swift")
        let surfaceSource = try sourceFile("Sources/KurottyApp/TerminalSurfaceView.swift")

        XCTAssertTrue(sessionSource.contains("var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)? { get set }"))
        XCTAssertTrue(shellSource.contains("var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?"))
        XCTAssertTrue(shellSource.contains("private var ptyReadTraceSequence: UInt64 = 0"))
        XCTAssertTrue(shellSource.contains("emitRuntimePtyRead(byteCount: chunk.count)"))
        XCTAssertTrue(shellSource.contains(".ptyRead(traceID: traceID, byteCount: byteCount)"))
        XCTAssertTrue(shellSource.contains("onRuntimeEvent?(event)"))
        XCTAssertTrue(surfaceSource.contains("private static let runtimeEventLedgerCapacity = 4_096"))
        XCTAssertTrue(surfaceSource.contains("private var runtimeEventLedger = TerminalEventLedger(capacity: TerminalSurfaceView.runtimeEventLedgerCapacity)"))
        XCTAssertTrue(surfaceSource.contains("shell.onRuntimeEvent = { [weak self] event in"))
        XCTAssertTrue(surfaceSource.contains("self?.recordRuntimeEvent(event)"))
        XCTAssertTrue(surfaceSource.contains("private func recordRuntimeEvent(_ event: TerminalEventLedger.RecordedEvent)"))
        XCTAssertFalse(surfaceSource.contains("runtimeEventLedger.recordPtyRead(traceID: event.traceID, data:"))
    }

    func testRuntimeBatchCorrelatesLiveBoundaryMetadataUnderStableTraceID() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("runtime-42")
        var batch = TerminalRuntimeEventBatch(traceID: traceID)

        batch.recordPtyRead(byteCount: 14)
        batch.recordParserEvent(.escapeSequence(kind: "CSI", byteCount: 5))
        batch.recordScreenMutation(.writeCells(cellCount: 9))
        batch.recordRenderFrame(.init(frameIndex: 6, dirtyRegionCount: 2, fullRedraw: false))

        let summary = batch.commit(to: &ledger)

        XCTAssertEqual(batch.recordedEvents.map(\.traceID), [traceID, traceID, traceID, traceID])
        XCTAssertEqual(ledger.events.map(\.traceID), [traceID, traceID, traceID, traceID])
        XCTAssertEqual(ledger.events.map(\.kind), [.ptyRead, .parserEvent, .screenMutation, .renderFrame])
        XCTAssertEqual(summary.traceID, traceID)
        XCTAssertEqual(summary.eventCount, 4)
        XCTAssertEqual(summary.ptyReadByteCount, 14)
        XCTAssertEqual(summary.parserEventByteCount, 5)
        XCTAssertEqual(summary.screenMutationCount, 1)
        XCTAssertEqual(summary.renderFrameCount, 1)
        XCTAssertEqual(summary.dirtyRegionCount, 2)
    }

    func testRuntimeBatchSummaryIsMetadataOnlyAndDoesNotRequireRawPayload() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("metadata-only")
        let secretBytes = Data("secret-token".utf8)
        var batch = TerminalRuntimeEventBatch(traceID: traceID)

        batch.recordPtyRead(metadata: TerminalRawPtyLogMetadata(data: secretBytes))
        batch.recordParserEvent(.printable(byteCount: secretBytes.count))
        batch.recordScreenMutation(.writeCells(cellCount: 12))
        batch.recordRenderFrame(.init(frameIndex: 8, dirtyRegionCount: 1, fullRedraw: true))

        let batchSummary = batch.summary
        let committedSummary = batch.commit(to: &ledger)
        let batchText = [
            batch.description,
            batchSummary.description,
            committedSummary.description,
            ledger.conciseDescription(for: traceID),
        ].joined(separator: "\n")

        XCTAssertEqual(batchSummary.traceID, traceID)
        XCTAssertEqual(batchSummary.eventCount, 4)
        XCTAssertEqual(batchSummary.ptyReadByteCount, secretBytes.count)
        XCTAssertEqual(batchSummary.parserEventByteCount, secretBytes.count)
        XCTAssertEqual(batchSummary.fullRedrawCount, 1)
        XCTAssertFalse(batchText.contains("secret-token"))
        XCTAssertTrue(batchText.contains("ptyBytes=12"))
        XCTAssertTrue(batchText.contains("parserBytes=12"))
    }

    func testRuntimeBatchRetentionIsBoundedBeforeCommit() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("bounded-runtime-batch")
        var batch = TerminalRuntimeEventBatch(traceID: traceID, capacity: 3)

        batch.recordPtyRead(byteCount: 1)
        batch.recordParserEvent(.printable(byteCount: 2))
        batch.recordScreenMutation(.writeCells(cellCount: 3))
        batch.recordRenderFrame(.init(frameIndex: 4, dirtyRegionCount: 5, fullRedraw: false))

        XCTAssertEqual(batch.capacity, 3)
        XCTAssertEqual(batch.droppedEventCount, 1)
        XCTAssertEqual(batch.recordedEvents.map(\.payload.kind), [.parserEvent, .screenMutation, .renderFrame])
        XCTAssertEqual(batch.summary.eventCount, 3)
        XCTAssertEqual(batch.summary.droppedEventCount, 1)

        let committedSummary = batch.commit(to: &ledger)

        XCTAssertEqual(ledger.events.map(\.kind), [.parserEvent, .screenMutation, .renderFrame])
        XCTAssertEqual(committedSummary.eventCount, 3)
        XCTAssertEqual(committedSummary.droppedEventCount, 0)
    }

    func testRuntimeBatchZeroCapacityDropsAllEventsBeforeCommit() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("zero-runtime-batch")
        var batch = TerminalRuntimeEventBatch(traceID: traceID, capacity: 0)

        batch.recordPtyRead(byteCount: 1)
        batch.recordParserEvent(.printable(byteCount: 2))

        XCTAssertTrue(batch.recordedEvents.isEmpty)
        XCTAssertEqual(batch.droppedEventCount, 2)
        XCTAssertEqual(batch.summary.eventCount, 0)
        XCTAssertEqual(batch.summary.droppedEventCount, 2)

        let committedSummary = batch.commit(to: &ledger)

        XCTAssertTrue(ledger.events.isEmpty)
        XCTAssertEqual(committedSummary.eventCount, 0)
        XCTAssertEqual(committedSummary.droppedEventCount, 0)
    }

    func testTraceCorrelationReportConnectsPipelineStagesWithoutPayloadText() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("pipeline")
        let secretBytes = Data("token=secret".utf8)

        ledger.recordPtyRead(traceID: traceID, data: secretBytes)
        ledger.recordParserEvent(traceID: traceID, event: .printable(byteCount: secretBytes.count))
        ledger.recordScreenMutation(traceID: traceID, mutation: .writeCells(cellCount: 12))
        ledger.recordRenderFrame(traceID: traceID, frame: .init(frameIndex: 2, dirtyRegionCount: 1, fullRedraw: false))

        let report = ledger.traceCorrelationReport(for: traceID)

        XCTAssertEqual(report.traceID, traceID)
        XCTAssertEqual(report.stageSequence, [.ptyRead, .parserEvent, .screenMutation, .renderFrame])
        XCTAssertTrue(report.hasCompleteRenderPath)
        XCTAssertEqual(report.resizeSourceOfTruth, nil)
        XCTAssertEqual(
            report.description,
            "trace=pipeline path=ptyRead>parserEvent>screenMutation>renderFrame complete=true resize=unavailable issues=0 ptyBytes=12 parserBytes=12 screenMutations=1 renderFrames=1 dirtyRegions=1 fullRedraws=0 droppedEvents=0"
        )
        XCTAssertFalse(report.description.contains("token=secret"))
    }

    func testTraceCorrelationReportCarriesResizeValidationSummary() {
        var ledger = TerminalEventLedger(capacity: 10)
        let traceID = TerminalEventTraceID("resize-pipeline")
        ledger.recordBatch([
            .ptyRead(traceID: traceID, byteCount: 4),
            .parserEvent(traceID: traceID, event: .escapeSequence(kind: "CSI", byteCount: 4)),
            .screenMutation(traceID: traceID, mutation: .resize(columns: 120, rows: 40)),
            .renderFrame(traceID: traceID, frame: .init(frameIndex: 3, dirtyRegionCount: 2, fullRedraw: true)),
        ])
        let resize = TerminalResizeCycleSnapshot(
            traceID: "resize-pipeline",
            source: "view-measurement",
            viewportSize: TerminalFrameSize(width: 1080, height: 720),
            cellSize: TerminalFrameSize(width: 9, height: 18),
            ptyColumns: 120,
            ptyRows: 40,
            screenColumns: 119,
            screenRows: 40,
            rendererColumns: 120,
            rendererRows: 40
        )

        let report = ledger.traceCorrelationReport(for: traceID, resizeSnapshot: resize)

        XCTAssertEqual(report.resizeSourceOfTruth?.source, "view-measurement")
        XCTAssertEqual(report.resizeSourceOfTruth?.derivedGrid, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(report.resizeSourceOfTruth?.issueCount, 1)
        XCTAssertEqual(report.resizeValidationIssues, [
            .screenMismatch(
                expected: TerminalResizeGridSize(columns: 120, rows: 40),
                actual: TerminalResizeGridSize(columns: 119, rows: 40)
            ),
        ])
        XCTAssertTrue(report.description.contains("resize=source=view-measurement derived=120x40 pty=120x40 screen=119x40 renderer=120x40 drawable=unavailable frame=unavailable disagree=screen valid=false issueCount=1"))
        XCTAssertFalse(report.description.contains("CSI"))
    }
}

private func sourceFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: sourceRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
