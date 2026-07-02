import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class TerminalResizeLedgerTests: XCTestCase {
    func testMatchedCycleHasNoValidationIssues() {
        let snapshot = makeSnapshot()

        XCTAssertTrue(snapshot.validationReport.isValid)
        XCTAssertEqual(snapshot.validationReport.issues, [])
        XCTAssertEqual(snapshot.derivedGrid, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(snapshot.validationReport.description, "resize-ledger ok")
    }

    func testPtyMismatchIsReportedAgainstDerivedGrid() {
        let snapshot = makeSnapshot(ptyColumns: 119, ptyRows: 40)

        XCTAssertEqual(snapshot.validationReport.issues, [
            .ptyMismatch(
                expected: TerminalResizeGridSize(columns: 120, rows: 40),
                actual: TerminalResizeGridSize(columns: 119, rows: 40)
            ),
        ])
        XCTAssertEqual(
            snapshot.validationReport.description,
            "pty mismatch expected=120x40 actual=119x40"
        )
    }

    func testRendererMismatchIsReportedAgainstDerivedGrid() {
        let snapshot = makeSnapshot(rendererColumns: 120, rendererRows: 39)

        XCTAssertEqual(snapshot.validationReport.issues, [
            .rendererMismatch(
                expected: TerminalResizeGridSize(columns: 120, rows: 40),
                actual: TerminalResizeGridSize(columns: 120, rows: 39)
            ),
        ])
        XCTAssertEqual(
            snapshot.validationReport.description,
            "renderer mismatch expected=120x40 actual=120x39"
        )
    }

    func testGridDerivationAndReportedSizesClampToPtyWinsizeRange() {
        let snapshot = TerminalResizeCycleSnapshot(
            viewportSize: TerminalFrameSize(width: 0, height: 700_000),
            cellSize: TerminalFrameSize(width: 10, height: 1),
            ptyColumns: 0,
            ptyRows: 70_000,
            screenColumns: -20,
            screenRows: 80_000,
            rendererColumns: 0,
            rendererRows: 100_000
        )

        let clamped = TerminalResizeGridSize(columns: 1, rows: Int(UInt16.max))
        XCTAssertEqual(snapshot.derivedGrid, clamped)
        XCTAssertEqual(snapshot.ptyWinsize, clamped)
        XCTAssertEqual(snapshot.screenSize, clamped)
        XCTAssertEqual(snapshot.renderer.gridSize, clamped)
        XCTAssertTrue(snapshot.validationReport.isValid)
    }

    func testMalformedMeasurementsClampWithoutTrapping() {
        let nonFiniteViewport = TerminalResizeCycleSnapshot(
            viewportSize: TerminalFrameSize(width: .nan, height: .infinity),
            cellSize: TerminalFrameSize(width: 9, height: 18),
            ptyColumns: 1,
            ptyRows: 1,
            screenColumns: 1,
            screenRows: 1,
            rendererColumns: 1,
            rendererRows: 1
        )
        let nonFiniteCell = TerminalResizeCycleSnapshot(
            viewportSize: TerminalFrameSize(width: 1080, height: 720),
            cellSize: TerminalFrameSize(width: .nan, height: .infinity),
            ptyColumns: 1,
            ptyRows: 1,
            screenColumns: 1,
            screenRows: 1,
            rendererColumns: 1,
            rendererRows: 1
        )
        let hugeViewport = TerminalResizeCycleSnapshot(
            viewportSize: TerminalFrameSize(width: Double.greatestFiniteMagnitude, height: 720),
            cellSize: TerminalFrameSize(width: 1, height: 18),
            ptyColumns: Int(UInt16.max),
            ptyRows: 40,
            screenColumns: Int(UInt16.max),
            screenRows: 40,
            rendererColumns: Int(UInt16.max),
            rendererRows: 40
        )

        XCTAssertEqual(nonFiniteViewport.derivedGrid, TerminalResizeGridSize(columns: 1, rows: 1))
        XCTAssertTrue(nonFiniteViewport.validationReport.isValid)
        XCTAssertEqual(nonFiniteCell.derivedGrid, TerminalResizeGridSize(columns: 1, rows: 1))
        XCTAssertTrue(nonFiniteCell.validationReport.isValid)
        XCTAssertEqual(hugeViewport.derivedGrid, TerminalResizeGridSize(columns: Int(UInt16.max), rows: 40))
        XCTAssertTrue(hugeViewport.validationReport.isValid)
    }

    func testDescriptionIsConciseAndMetadataOnly() {
        let snapshot = makeSnapshot(
            traceID: "resize-42",
            source: "surface",
            timestamp: 12.3456,
            rendererDrawableSize: TerminalFrameSize(width: 1080, height: 720),
            rendererFrameSize: TerminalFrameSize(width: 1080, height: 720)
        )

        XCTAssertEqual(
            snapshot.description,
            "trace=resize-42 source=surface timestamp=12.346 view=1080.00x720.00 cell=9.00x18.00 derived=120x40 pty=120x40 screen=120x40 renderer=120x40 drawable=1080.00x720.00 frame=1080.00x720.00 issues=0"
        )
        XCTAssertFalse(snapshot.description.contains("token="))
        XCTAssertFalse(snapshot.description.contains("/Users/"))
    }

    func testTraceAdapterBuildsLedgerSnapshotFromExistingResizeDiagnostics() throws {
        let trace = TerminalResizeTrace(
            requestedColumns: 120,
            requestedRows: 40,
            cellSize: TerminalFrameSize(width: 9, height: 18),
            viewSize: TerminalFrameSize(width: 1080, height: 720),
            ioctlResult: 0,
            ioctlErrno: nil,
            didSendSIGWINCH: true
        )

        let snapshot = try XCTUnwrap(TerminalResizeCycleSnapshot(
            trace: trace,
            traceID: "resize-token",
            source: "pty",
            timestamp: 1.25,
            screenColumns: 120,
            screenRows: 40,
            rendererColumns: 119,
            rendererRows: 40,
            rendererDrawableSize: TerminalFrameSize(width: 1080, height: 720),
            rendererFrameSize: TerminalFrameSize(width: 1080, height: 720)
        ))

        XCTAssertEqual(snapshot.derivedGrid, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(snapshot.ptyWinsize, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(snapshot.screenSize, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(snapshot.renderer.gridSize, TerminalResizeGridSize(columns: 119, rows: 40))
        XCTAssertEqual(snapshot.validationReport.issues, [
            .rendererMismatch(
                expected: TerminalResizeGridSize(columns: 120, rows: 40),
                actual: TerminalResizeGridSize(columns: 119, rows: 40)
            ),
        ])
        XCTAssertEqual(
            snapshot.description,
            "trace=resize-token source=pty timestamp=1.250 view=1080.00x720.00 cell=9.00x18.00 derived=120x40 pty=120x40 screen=120x40 renderer=119x40 drawable=1080.00x720.00 frame=1080.00x720.00 issues=1"
        )
        XCTAssertFalse(snapshot.description.contains("requested="))
        XCTAssertFalse(snapshot.description.contains("token=secret"))
        XCTAssertFalse(snapshot.description.contains("/Users/"))
    }

    func testTraceAdapterReturnsNilWhenTraceDoesNotCarryMeasurements() {
        let trace = TerminalResizeTrace(
            requestedColumns: 120,
            requestedRows: 40,
            cellSize: nil,
            viewSize: nil,
            ioctlResult: 0,
            ioctlErrno: nil,
            didSendSIGWINCH: true
        )

        XCTAssertNil(TerminalResizeCycleSnapshot(
            trace: trace,
            screenColumns: 120,
            screenRows: 40,
            rendererColumns: 120,
            rendererRows: 40
        ))
    }

    func testTraceAdapterPreservesWinsizeAndNonFiniteLedgerClamps() throws {
        let trace = TerminalResizeTrace(
            requestedColumns: 0,
            requestedRows: 70_000,
            cellSize: TerminalFrameSize(width: .nan, height: .infinity),
            viewSize: TerminalFrameSize(width: .nan, height: .infinity),
            ioctlResult: -1,
            ioctlErrno: 25,
            didSendSIGWINCH: false
        )

        let snapshot = try XCTUnwrap(TerminalResizeCycleSnapshot(
            trace: trace,
            screenColumns: 1,
            screenRows: 1,
            rendererColumns: 1,
            rendererRows: 1
        ))

        XCTAssertEqual(snapshot.derivedGrid, TerminalResizeGridSize(columns: 1, rows: 1))
        XCTAssertEqual(snapshot.ptyWinsize, TerminalResizeGridSize(columns: 1, rows: Int(UInt16.max)))
        XCTAssertEqual(snapshot.validationReport.issues, [
            .ptyMismatch(
                expected: TerminalResizeGridSize(columns: 1, rows: 1),
                actual: TerminalResizeGridSize(columns: 1, rows: Int(UInt16.max))
            ),
        ])
    }

    func testSourceOfTruthSummaryReportsValidationMetadataOnly() {
        let snapshot = makeSnapshot(
            traceID: "resize-secret",
            source: "view-measurement",
            screenColumns: 119,
            screenRows: 40
        )

        let summary = TerminalResizeSourceOfTruthSummary(snapshot: snapshot)

        XCTAssertEqual(summary.source, "view-measurement")
        XCTAssertEqual(summary.derivedGrid, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(summary.ptyWinsize, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertEqual(summary.screenSize, TerminalResizeGridSize(columns: 119, rows: 40))
        XCTAssertEqual(summary.rendererGrid, TerminalResizeGridSize(columns: 120, rows: 40))
        XCTAssertFalse(summary.isValid)
        XCTAssertEqual(summary.issueCount, 1)
        XCTAssertEqual(
            summary.description,
            "source=view-measurement derived=120x40 pty=120x40 screen=119x40 renderer=120x40 valid=false issueCount=1"
        )
        XCTAssertFalse(summary.description.contains("secret"))
        XCTAssertFalse(summary.description.contains("/Users/"))
    }

    private func makeSnapshot(
        traceID: String? = nil,
        source: String? = nil,
        timestamp: TimeInterval? = nil,
        ptyColumns: Int = 120,
        ptyRows: Int = 40,
        screenColumns: Int = 120,
        screenRows: Int = 40,
        rendererColumns: Int = 120,
        rendererRows: Int = 40,
        rendererDrawableSize: TerminalFrameSize? = nil,
        rendererFrameSize: TerminalFrameSize? = nil
    ) -> TerminalResizeCycleSnapshot {
        TerminalResizeCycleSnapshot(
            traceID: traceID,
            source: source,
            timestamp: timestamp,
            viewportSize: TerminalFrameSize(width: 1080, height: 720),
            cellSize: TerminalFrameSize(width: 9, height: 18),
            ptyColumns: ptyColumns,
            ptyRows: ptyRows,
            screenColumns: screenColumns,
            screenRows: screenRows,
            rendererColumns: rendererColumns,
            rendererRows: rendererRows,
            rendererDrawableSize: rendererDrawableSize,
            rendererFrameSize: rendererFrameSize
        )
    }
}
