import XCTest
@testable import KurottyApp

final class SegmentedScrollbackStoreTests: XCTestCase {
    func testSegmentRolloverUsesFixedSizeChunks() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 10, segmentSize: 3)

        let visibleAppendCount = store.append(contentsOf: Array(0..<7))

        XCTAssertEqual(visibleAppendCount, 7)
        XCTAssertEqual(store.count, 7)
        XCTAssertEqual(store.diagnostics.segmentCount, 3)
        XCTAssertEqual((0..<7).map { store.row(at: $0) }, Array(0..<7).map(Optional.some))
    }

    func testAppendTrimsToRowLimitAndPreservesVisibleLookupOrder() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 5, segmentSize: 3)

        let visibleAppendCount = store.append(contentsOf: Array(0..<8))

        XCTAssertEqual(visibleAppendCount, 5)
        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.diagnostics.visibleRowCount, 5)
        XCTAssertEqual(store.diagnostics.droppedRowCount, 3)
        XCTAssertEqual(store.diagnostics.trimCount, 1)
        XCTAssertNil(store.row(at: -1))
        XCTAssertNil(store.row(at: 5))
        XCTAssertEqual((0..<5).map { store.row(at: $0) }, Array(3..<8).map(Optional.some))
    }

    func testAppendReportsNewRowsRetainedWhenStoreIsAlreadyAtLimit() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 3, segmentSize: 2)
        store.append(contentsOf: [1, 2, 3])

        let visibleAppendCount = store.append(4)

        XCTAssertTrue(visibleAppendCount)
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual((0..<3).map { store.row(at: $0) }, [2, 3, 4].map(Optional.some))
    }

    func testRepeatedAppendAtLimitKeepsCapacityAndTracksDrops() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 3, segmentSize: 2)
        store.append(contentsOf: [1, 2, 3])

        XCTAssertEqual(store.append(contentsOf: [4, 5]), 2)

        XCTAssertEqual(store.count, 3)
        XCTAssertEqual((0..<3).map { store.row(at: $0) }, [3, 4, 5].map(Optional.some))
        XCTAssertEqual(store.diagnostics.visibleRowCount, 3)
        XCTAssertEqual(store.diagnostics.droppedRowCount, 2)
        XCTAssertEqual(store.diagnostics.trimCount, 1)
        XCTAssertLessThanOrEqual(store.diagnostics.segmentCount, store.diagnostics.maximumRetainedSegmentCount)
        XCTAssertLessThanOrEqual(
            store.diagnostics.retainedStorageRowCount,
            store.diagnostics.maximumRetainedStorageRowCount
        )
    }

    func testExplicitTrimUpdatesLimitAndDroppedCount() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 10, segmentSize: 4)
        store.append(contentsOf: Array(0..<6))

        XCTAssertTrue(store.trim(to: 2))

        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.diagnostics.rowLimit, 2)
        XCTAssertEqual(store.diagnostics.droppedRowCount, 4)
        XCTAssertEqual(store.diagnostics.trimCount, 1)
        XCTAssertEqual(store.row(at: 0), 4)
        XCTAssertEqual(store.row(at: 1), 5)
    }

    func testZeroLimitDropsAllRowsAndRetainsNoSegments() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 0, segmentSize: 2)

        let visibleAppendCount = store.append(contentsOf: [1, 2, 3])

        XCTAssertEqual(visibleAppendCount, 0)
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.diagnostics.segmentCount, 0)
        XCTAssertEqual(store.diagnostics.visibleRowCount, 0)
        XCTAssertEqual(store.diagnostics.retainedStorageRowCount, 0)
        XCTAssertEqual(store.diagnostics.droppedRowCount, 3)
        XCTAssertEqual(store.diagnostics.trimCount, 1)
        XCTAssertNil(store.row(at: 0))
    }

    func testManyAppendsCapRetainedRowsAndSegments() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 10, segmentSize: 4)

        store.append(contentsOf: Array(0..<100))

        XCTAssertEqual(store.count, 10)
        XCTAssertEqual(store.row(at: 0), 90)
        XCTAssertEqual(store.row(at: 9), 99)
        XCTAssertLessThanOrEqual(store.diagnostics.segmentCount, store.diagnostics.maximumRetainedSegmentCount)
        XCTAssertLessThanOrEqual(
            store.diagnostics.retainedStorageRowCount,
            store.diagnostics.maximumRetainedStorageRowCount
        )
    }

    func testTailLookupAfterManySegmentDropsPreservesVisibleIndexes() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 1_000, segmentSize: 8)

        store.append(contentsOf: Array(0..<20_000))

        XCTAssertEqual(store.count, 1_000)
        XCTAssertEqual(store.row(at: 0), 19_000)
        XCTAssertEqual(store.row(at: 499), 19_499)
        XCTAssertEqual(store.row(at: 999), 19_999)
        XCTAssertLessThanOrEqual(store.diagnostics.segmentCount, store.diagnostics.maximumRetainedSegmentCount)
    }

    func testDiagnosticsDoNotExposeRowText() {
        var store = SegmentedScrollbackStore<String>(rowLimit: 2, segmentSize: 2)

        store.append(contentsOf: ["secret token", "normal output", "another secret"])

        let diagnosticsDescription = String(describing: store.diagnostics)
        XCTAssertFalse(diagnosticsDescription.contains("secret token"))
        XCTAssertFalse(diagnosticsDescription.contains("normal output"))
        XCTAssertFalse(diagnosticsDescription.contains("another secret"))
    }

    func testRetainedRowSummaryTracksAbsoluteCoordinatesWithoutRowText() {
        var store = SegmentedScrollbackStore<String>(rowLimit: 3, segmentSize: 2)

        store.append(contentsOf: ["secret token", "normal output", "another secret", "tail"])

        let summary = store.retainedRowSummary
        XCTAssertEqual(summary, .init(firstRetainedRowIndex: 1, retainedRowCount: 3, droppedRowCount: 1))
        XCTAssertEqual(summary.lastRetainedRowIndex, 3)
        XCTAssertEqual(summary.nextRowIndex, 4)
        XCTAssertEqual(store.visibleRowIndex(forAbsoluteRowIndex: 1), 0)
        XCTAssertEqual(store.visibleRowIndex(forAbsoluteRowIndex: 3), 2)
        XCTAssertNil(store.visibleRowIndex(forAbsoluteRowIndex: 0))
        XCTAssertNil(store.visibleRowIndex(forAbsoluteRowIndex: 4))
        XCTAssertEqual(store.absoluteRowIndex(forVisibleRowIndex: 0), 1)
        XCTAssertEqual(store.absoluteRowIndex(forVisibleRowIndex: 2), 3)
        XCTAssertNil(store.absoluteRowIndex(forVisibleRowIndex: -1))
        XCTAssertNil(store.absoluteRowIndex(forVisibleRowIndex: 3))
        XCTAssertFalse(String(describing: summary).contains("secret"))
        XCTAssertFalse(String(describing: store.diagnostics).contains("normal output"))
    }

    func testExportWindowSummaryBoundsMaterializationWithoutRowText() {
        var store = SegmentedScrollbackStore<String>(rowLimit: 4, segmentSize: 2)

        store.append(contentsOf: [
            "secret zero",
            "secret one",
            "normal two",
            "normal three",
            "tail four",
            "tail five",
        ])

        let summary = store.exportWindowSummary(
            absoluteStartIndex: 1,
            rowCount: 6,
            materializationLimit: 2
        )

        XCTAssertEqual(summary.requestedStartAbsoluteRowIndex, 1)
        XCTAssertEqual(summary.requestedRowCount, 6)
        XCTAssertEqual(summary.firstAvailableAbsoluteRowIndex, 2)
        XCTAssertEqual(summary.availableRowCount, 4)
        XCTAssertEqual(summary.boundedMaterializedRowCount, 2)
        XCTAssertEqual(summary.skippedDroppedRowCount, 1)
        XCTAssertEqual(summary.skippedFutureRowCount, 1)
        XCTAssertTrue(summary.requiresBoundedMaterialization)
        XCTAssertFalse(summary.isFullyRetained)
        XCTAssertFalse(String(describing: summary).contains("secret"))
        XCTAssertFalse(String(describing: summary).contains("normal"))
        XCTAssertFalse(String(describing: summary).contains("tail"))
    }

    func testMillionLineAppendKeepsRetainedStorageWithinPressureCeiling() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 1_000_000, segmentSize: 1_024)

        store.append(contentsOf: Array(0..<1_000_050))

        XCTAssertEqual(store.count, 1_000_000)
        XCTAssertEqual(store.retainedRowSummary, .init(
            firstRetainedRowIndex: 50,
            retainedRowCount: 1_000_000,
            droppedRowCount: 50
        ))
        XCTAssertEqual(store.row(at: 0), 50)
        XCTAssertEqual(store.row(at: 999_999), 1_000_049)
        XCTAssertLessThanOrEqual(store.diagnostics.segmentCount, store.diagnostics.maximumRetainedSegmentCount)
        XCTAssertLessThanOrEqual(
            store.diagnostics.retainedStorageRowCount,
            store.diagnostics.maximumRetainedStorageRowCount
        )
        XCTAssertEqual(store.visibleRowIndex(forAbsoluteRowIndex: 50), 0)
        XCTAssertEqual(store.visibleRowIndex(forAbsoluteRowIndex: 1_000_049), 999_999)
    }
}
