struct SegmentedScrollbackStore<Row> {
    struct Diagnostics: Equatable, CustomStringConvertible {
        let rowLimit: Int
        let segmentSize: Int
        let segmentCount: Int
        let visibleRowCount: Int
        let retainedStorageRowCount: Int
        let droppedRowCount: Int
        let trimCount: Int
        let compactionCount: Int
        let maximumRetainedSegmentCount: Int
        let maximumRetainedStorageRowCount: Int

        var description: String {
            [
                "rowLimit=\(rowLimit)",
                "segmentSize=\(segmentSize)",
                "segments=\(segmentCount)",
                "visibleRows=\(visibleRowCount)",
                "retainedStorageRows=\(retainedStorageRowCount)",
                "droppedRows=\(droppedRowCount)",
                "trims=\(trimCount)",
                "compactions=\(compactionCount)",
                "maxRetainedSegments=\(maximumRetainedSegmentCount)",
                "maxRetainedStorageRows=\(maximumRetainedStorageRowCount)",
            ].joined(separator: " ")
        }
    }

    private var segments: [[Row]] = []
    private var firstSegmentStartIndex = 0
    private var rowLimit: Int
    private let segmentSize: Int
    private var visibleRowCount = 0
    private var droppedRowCount = 0
    private var trimCount = 0
    private var compactionCount = 0

    init(rowLimit: Int, segmentSize: Int) {
        self.rowLimit = max(0, rowLimit)
        self.segmentSize = max(1, segmentSize)
    }

    var count: Int {
        visibleRowCount
    }

    var isEmpty: Bool {
        visibleRowCount == 0
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            rowLimit: rowLimit,
            segmentSize: segmentSize,
            segmentCount: segments.count,
            visibleRowCount: visibleRowCount,
            retainedStorageRowCount: retainedStorageRowCount,
            droppedRowCount: droppedRowCount,
            trimCount: trimCount,
            compactionCount: compactionCount,
            maximumRetainedSegmentCount: maximumRetainedSegmentCount,
            maximumRetainedStorageRowCount: maximumRetainedStorageRowCount
        )
    }

    @discardableResult
    mutating func append(_ row: Row) -> Bool {
        append(contentsOf: [row]) == 1
    }

    @discardableResult
    mutating func append(contentsOf rows: [Row]) -> Int {
        guard !rows.isEmpty else { return 0 }

        for row in rows {
            appendWithoutTrimming(row)
        }
        trimToLimit()

        return min(rows.count, rowLimit)
    }

    @discardableResult
    mutating func trim(to limit: Int) -> Bool {
        rowLimit = max(0, limit)
        return trimToLimit()
    }

    func row(at index: Int) -> Row? {
        guard index >= 0, index < visibleRowCount else { return nil }
        guard let firstSegment = segments.first else { return nil }

        let firstVisibleCount = firstSegment.count - firstSegmentStartIndex
        if index < firstVisibleCount {
            return firstSegment[firstSegmentStartIndex + index]
        }

        let remainingIndex = index - firstVisibleCount
        let segmentOffset = 1 + remainingIndex / segmentSize
        let rowOffset = remainingIndex % segmentSize
        guard segmentOffset < segments.count,
              rowOffset < segments[segmentOffset].count
        else {
            return nil
        }
        return segments[segmentOffset][rowOffset]
    }

    private var retainedStorageRowCount: Int {
        segments.reduce(0) { $0 + $1.count }
    }

    private var maximumRetainedSegmentCount: Int {
        guard rowLimit > 0 else { return 0 }
        return Int((rowLimit + segmentSize - 1) / segmentSize) + 1
    }

    private var maximumRetainedStorageRowCount: Int {
        guard rowLimit > 0 else { return 0 }
        return rowLimit + segmentSize - 1
    }

    private mutating func appendWithoutTrimming(_ row: Row) {
        if segments.last?.count == segmentSize || segments.isEmpty {
            segments.append([])
        }
        segments[segments.count - 1].append(row)
        visibleRowCount += 1
    }

    @discardableResult
    private mutating func trimToLimit() -> Bool {
        let rowsToDrop = visibleRowCount - rowLimit
        guard rowsToDrop > 0 else {
            compactSegmentsIfNeeded()
            return false
        }

        trimCount += 1
        droppedRowCount += rowsToDrop
        dropLeadingRows(rowsToDrop)
        compactSegmentsIfNeeded()
        return true
    }

    private mutating func dropLeadingRows(_ rowsToDrop: Int) {
        guard rowsToDrop > 0 else { return }
        if rowLimit == 0 {
            segments.removeAll(keepingCapacity: false)
            firstSegmentStartIndex = 0
            visibleRowCount = 0
            compactionCount += 1
            return
        }

        var remainingRowsToDrop = rowsToDrop
        while remainingRowsToDrop > 0, !segments.isEmpty {
            let visibleRowsInFirstSegment = segments[0].count - firstSegmentStartIndex
            if remainingRowsToDrop < visibleRowsInFirstSegment {
                firstSegmentStartIndex += remainingRowsToDrop
                visibleRowCount -= remainingRowsToDrop
                remainingRowsToDrop = 0
            } else {
                remainingRowsToDrop -= visibleRowsInFirstSegment
                visibleRowCount -= visibleRowsInFirstSegment
                segments.removeFirst()
                firstSegmentStartIndex = 0
                compactionCount += 1
            }
        }
    }

    private mutating func compactSegmentsIfNeeded() {
        guard !segments.isEmpty else {
            firstSegmentStartIndex = 0
            return
        }
        guard segments.count > maximumRetainedSegmentCount ||
            retainedStorageRowCount > maximumRetainedStorageRowCount
        else {
            return
        }

        let visibleRows = (0..<visibleRowCount).map { row(at: $0)! }
        segments = []
        firstSegmentStartIndex = 0
        for row in visibleRows {
            appendWithoutTrimming(row)
        }
        visibleRowCount = visibleRows.count
        compactionCount += 1
    }
}
