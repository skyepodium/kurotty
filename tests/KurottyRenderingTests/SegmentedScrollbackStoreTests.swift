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

    func testDiagnosticsDoNotExposeRowText() {
        var store = SegmentedScrollbackStore<String>(rowLimit: 2, segmentSize: 2)

        store.append(contentsOf: ["secret token", "normal output", "another secret"])

        let diagnosticsDescription = String(describing: store.diagnostics)
        XCTAssertFalse(diagnosticsDescription.contains("secret token"))
        XCTAssertFalse(diagnosticsDescription.contains("normal output"))
        XCTAssertFalse(diagnosticsDescription.contains("another secret"))
    }
}
