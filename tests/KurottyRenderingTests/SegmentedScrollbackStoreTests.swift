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

    func testLiveAccessSummaryClassifiesSearchCopyAndAIWindowsWithoutRowText() {
        var store = SegmentedScrollbackStore<String>(rowLimit: 4, segmentSize: 2)

        store.append(contentsOf: [
            "secret zero",
            "secret one",
            "normal two",
            "normal three",
            "tail four",
            "tail five",
        ])

        let copySummary = store.liveAccessSummary(
            purpose: .copyMode,
            absoluteStartIndex: 2,
            rowCount: 3,
            materializationLimit: 8
        )
        let searchSummary = store.liveAccessSummary(
            purpose: .search,
            absoluteStartIndex: 1,
            rowCount: 6,
            materializationLimit: 2
        )
        let aiSummary = store.liveAccessSummary(
            purpose: .aiContextReference,
            absoluteStartIndex: 5,
            rowCount: 5,
            materializationLimit: 1
        )

        XCTAssertEqual(copySummary.purpose, .copyMode)
        XCTAssertEqual(copySummary.availability, .fullyAvailable)
        XCTAssertTrue(copySummary.canServeSynchronously)
        XCTAssertFalse(copySummary.requiresUserVisibleWarning)

        XCTAssertEqual(searchSummary.purpose, .search)
        XCTAssertEqual(searchSummary.availability, .partiallyDroppedAndFuture)
        XCTAssertFalse(searchSummary.canServeSynchronously)
        XCTAssertTrue(searchSummary.requiresUserVisibleWarning)

        XCTAssertEqual(aiSummary.purpose, .aiContextReference)
        XCTAssertEqual(aiSummary.availability, .partiallyFuture)
        XCTAssertFalse(aiSummary.canServeSynchronously)
        XCTAssertTrue(aiSummary.requiresUserVisibleWarning)
        XCTAssertTrue(String(describing: aiSummary).contains("purpose=aiContextReference"))
        XCTAssertFalse(String(describing: searchSummary).contains("secret"))
        XCTAssertFalse(String(describing: searchSummary).contains("normal"))
        XCTAssertFalse(String(describing: searchSummary).contains("tail"))
    }

    func testPersistenceSnapshotIsCodableMetadataOnly() throws {
        var store = SegmentedScrollbackStore<String>(rowLimit: 5, segmentSize: 3)

        store.append(contentsOf: [
            "secret zero",
            "secret one",
            "normal two",
            "normal three",
            "tail four",
            "tail five",
            "tail six",
        ])

        let snapshot = store.persistenceSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.rowLimit, 5)
        XCTAssertEqual(snapshot.segmentSize, 3)
        XCTAssertEqual(snapshot.retainedRowSummary, .init(
            firstRetainedRowIndex: 2,
            retainedRowCount: 5,
            droppedRowCount: 2
        ))
        XCTAssertEqual(snapshot.segments, [
            .init(
                ordinal: 0,
                absoluteStartRowIndex: 2,
                visibleRowCount: 1,
                retainedStorageRowCount: 3,
                isFirstPartialSegment: true,
                isMutableTailSegment: false
            ),
            .init(
                ordinal: 1,
                absoluteStartRowIndex: 3,
                visibleRowCount: 3,
                retainedStorageRowCount: 3,
                isFirstPartialSegment: false,
                isMutableTailSegment: false
            ),
            .init(
                ordinal: 2,
                absoluteStartRowIndex: 6,
                visibleRowCount: 1,
                retainedStorageRowCount: 1,
                isFirstPartialSegment: false,
                isMutableTailSegment: true
            ),
        ])
        XCTAssertEqual(snapshot.spillCandidateSegmentCount, 1)
        XCTAssertEqual(snapshot.spillCandidateRowCount, 3)

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            SegmentedScrollbackStore<String>.PersistenceSnapshot.self,
            from: encoded
        )
        XCTAssertEqual(decoded, snapshot)

        let encodedDescription = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedDescription.contains("secret"))
        XCTAssertFalse(encodedDescription.contains("normal"))
        XCTAssertFalse(encodedDescription.contains("tail"))
    }

    func testPersistenceSnapshotKeepsLargeStoreMetadataBounded() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 10_000, segmentSize: 256)

        store.append(contentsOf: Array(0..<50_000))

        let snapshot = store.persistenceSnapshot()

        XCTAssertEqual(snapshot.retainedRowSummary, .init(
            firstRetainedRowIndex: 40_000,
            retainedRowCount: 10_000,
            droppedRowCount: 40_000
        ))
        XCTAssertEqual(snapshot.segments.reduce(0) { $0 + $1.visibleRowCount }, 10_000)
        XCTAssertEqual(
            snapshot.segments.map(\.visibleRowCount).max(),
            256
        )
        XCTAssertLessThanOrEqual(
            snapshot.segments.count,
            store.diagnostics.maximumRetainedSegmentCount
        )
        XCTAssertGreaterThan(snapshot.spillCandidateSegmentCount, 0)
        XCTAssertGreaterThan(snapshot.spillCandidateRowCount, 0)
        XCTAssertLessThan(snapshot.segments.count, 50)
    }

    func testPersistenceSnapshotTreatsFullTailSegmentAsClosedForSpill() {
        var store = SegmentedScrollbackStore<Int>(rowLimit: 6, segmentSize: 3)

        store.append(contentsOf: Array(0..<6))

        let snapshot = store.persistenceSnapshot()

        XCTAssertEqual(snapshot.segments.count, 2)
        XCTAssertEqual(snapshot.segments.map(\.isMutableTailSegment), [false, false])
        XCTAssertEqual(snapshot.spillCandidateSegmentCount, 2)
        XCTAssertEqual(snapshot.spillCandidateRowCount, 6)
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
