struct SegmentedScrollbackStore<Row> {
    struct RetainedRowSummary: Codable, Equatable, CustomStringConvertible {
        let firstRetainedRowIndex: Int
        let retainedRowCount: Int
        let droppedRowCount: Int

        var lastRetainedRowIndex: Int? {
            guard retainedRowCount > 0 else { return nil }
            return firstRetainedRowIndex + retainedRowCount - 1
        }

        var nextRowIndex: Int {
            firstRetainedRowIndex + retainedRowCount
        }

        func contains(absoluteRowIndex: Int) -> Bool {
            absoluteRowIndex >= firstRetainedRowIndex && absoluteRowIndex < nextRowIndex
        }

        var description: String {
            [
                "firstRetainedRow=\(firstRetainedRowIndex)",
                "lastRetainedRow=\(lastRetainedRowIndex.map(String.init) ?? "none")",
                "retainedRows=\(retainedRowCount)",
                "droppedRows=\(droppedRowCount)",
                "nextRow=\(nextRowIndex)",
            ].joined(separator: " ")
        }
    }

    struct PersistenceSegmentDescriptor: Codable, Equatable, CustomStringConvertible {
        let ordinal: Int
        let absoluteStartRowIndex: Int
        let visibleRowCount: Int
        let retainedStorageRowCount: Int
        let isFirstPartialSegment: Bool
        let isMutableTailSegment: Bool

        var canSpillWithoutCompaction: Bool {
            !isFirstPartialSegment && !isMutableTailSegment
        }

        var absoluteEndRowIndex: Int {
            absoluteStartRowIndex + visibleRowCount
        }

        var description: String {
            [
                "ordinal=\(ordinal)",
                "absoluteStartRow=\(absoluteStartRowIndex)",
                "absoluteEndRow=\(absoluteEndRowIndex)",
                "visibleRows=\(visibleRowCount)",
                "retainedStorageRows=\(retainedStorageRowCount)",
                "firstPartial=\(isFirstPartialSegment)",
                "mutableTail=\(isMutableTailSegment)",
                "canSpillWithoutCompaction=\(canSpillWithoutCompaction)",
            ].joined(separator: " ")
        }
    }

    struct PersistenceSnapshot: Codable, Equatable, CustomStringConvertible {
        let schemaVersion: Int
        let rowLimit: Int
        let segmentSize: Int
        let retainedRowSummary: RetainedRowSummary
        let segments: [PersistenceSegmentDescriptor]

        var spillCandidateSegmentCount: Int {
            segments.filter(\.canSpillWithoutCompaction).count
        }

        var spillCandidateRowCount: Int {
            segments.reduce(0) { total, segment in
                total + (segment.canSpillWithoutCompaction ? segment.visibleRowCount : 0)
            }
        }

        var description: String {
            [
                "schemaVersion=\(schemaVersion)",
                "rowLimit=\(rowLimit)",
                "segmentSize=\(segmentSize)",
                "retainedRange=\(retainedRowSummary)",
                "segments=\(segments.count)",
                "spillCandidateSegments=\(spillCandidateSegmentCount)",
                "spillCandidateRows=\(spillCandidateRowCount)",
            ].joined(separator: " ")
        }
    }

    struct ExportWindowSummary: Equatable, CustomStringConvertible {
        let requestedStartAbsoluteRowIndex: Int
        let requestedRowCount: Int
        let firstAvailableAbsoluteRowIndex: Int?
        let availableRowCount: Int
        let boundedMaterializedRowCount: Int
        let materializationLimit: Int
        let skippedDroppedRowCount: Int
        let skippedFutureRowCount: Int
        let retainedRowSummary: RetainedRowSummary

        var requiresBoundedMaterialization: Bool {
            availableRowCount > boundedMaterializedRowCount
        }

        var isFullyRetained: Bool {
            requestedRowCount == availableRowCount
        }

        var description: String {
            [
                "requestedStartRow=\(requestedStartAbsoluteRowIndex)",
                "requestedRows=\(requestedRowCount)",
                "firstAvailableRow=\(firstAvailableAbsoluteRowIndex.map(String.init) ?? "none")",
                "availableRows=\(availableRowCount)",
                "boundedMaterializedRows=\(boundedMaterializedRowCount)",
                "materializationLimit=\(materializationLimit)",
                "skippedDroppedRows=\(skippedDroppedRowCount)",
                "skippedFutureRows=\(skippedFutureRowCount)",
                "requiresBoundedMaterialization=\(requiresBoundedMaterialization)",
                "retainedRange=\(retainedRowSummary)",
            ].joined(separator: " ")
        }
    }

    enum LiveAccessPurpose: String, Equatable, CustomStringConvertible {
        case search
        case copyMode
        case aiContextReference

        var description: String { rawValue }
    }

    enum LiveAccessAvailability: String, Equatable, CustomStringConvertible {
        case fullyAvailable
        case fullyDropped
        case fullyFuture
        case partiallyDropped
        case partiallyFuture
        case partiallyDroppedAndFuture
        case emptyRequest

        var description: String { rawValue }
    }

    struct LiveAccessSummary: Equatable, CustomStringConvertible {
        let purpose: LiveAccessPurpose
        let exportWindow: ExportWindowSummary
        let availability: LiveAccessAvailability

        var canServeSynchronously: Bool {
            availability == .fullyAvailable && !exportWindow.requiresBoundedMaterialization
        }

        var requiresUserVisibleWarning: Bool {
            !canServeSynchronously
        }

        var description: String {
            [
                "purpose=\(purpose)",
                "availability=\(availability)",
                "canServeSynchronously=\(canServeSynchronously)",
                "requiresUserVisibleWarning=\(requiresUserVisibleWarning)",
                "window=\(exportWindow)",
            ].joined(separator: " ")
        }
    }

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
        let retainedRowSummary: RetainedRowSummary

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
                "retainedRange=\(retainedRowSummary)",
            ].joined(separator: " ")
        }
    }

    private var segments: [[Row]] = []
    private var firstRetainedSegmentIndex = 0
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
            segmentCount: retainedSegmentCount,
            visibleRowCount: visibleRowCount,
            retainedStorageRowCount: retainedStorageRowCount,
            droppedRowCount: droppedRowCount,
            trimCount: trimCount,
            compactionCount: compactionCount,
            maximumRetainedSegmentCount: maximumRetainedSegmentCount,
            maximumRetainedStorageRowCount: maximumRetainedStorageRowCount,
            retainedRowSummary: retainedRowSummary
        )
    }

    var retainedRowSummary: RetainedRowSummary {
        RetainedRowSummary(
            firstRetainedRowIndex: droppedRowCount,
            retainedRowCount: visibleRowCount,
            droppedRowCount: droppedRowCount
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
        guard firstRetainedSegmentIndex < segments.count else { return nil }

        let firstSegment = segments[firstRetainedSegmentIndex]
        let firstVisibleCount = firstSegment.count - firstSegmentStartIndex
        if index < firstVisibleCount {
            return firstSegment[firstSegmentStartIndex + index]
        }

        let remainingIndex = index - firstVisibleCount
        let segmentOffset = firstRetainedSegmentIndex + 1 + remainingIndex / segmentSize
        let rowOffset = remainingIndex % segmentSize
        guard segmentOffset < segments.count,
              rowOffset < segments[segmentOffset].count
        else {
            return nil
        }
        return segments[segmentOffset][rowOffset]
    }

    func absoluteRowIndex(forVisibleRowIndex visibleRowIndex: Int) -> Int? {
        guard visibleRowIndex >= 0, visibleRowIndex < visibleRowCount else {
            return nil
        }
        return droppedRowCount + visibleRowIndex
    }

    func visibleRowIndex(forAbsoluteRowIndex absoluteRowIndex: Int) -> Int? {
        guard retainedRowSummary.contains(absoluteRowIndex: absoluteRowIndex) else {
            return nil
        }
        return absoluteRowIndex - droppedRowCount
    }

    func exportWindowSummary(
        absoluteStartIndex: Int,
        rowCount: Int,
        materializationLimit: Int
    ) -> ExportWindowSummary {
        Self.exportWindowSummary(
            absoluteStartIndex: absoluteStartIndex,
            rowCount: rowCount,
            materializationLimit: materializationLimit,
            retainedRowSummary: retainedRowSummary
        )
    }

    func liveAccessSummary(
        purpose: LiveAccessPurpose,
        absoluteStartIndex: Int,
        rowCount: Int,
        materializationLimit: Int
    ) -> LiveAccessSummary {
        Self.liveAccessSummary(
            purpose: purpose,
            absoluteStartIndex: absoluteStartIndex,
            rowCount: rowCount,
            materializationLimit: materializationLimit,
            retainedRowSummary: retainedRowSummary
        )
    }

    func persistenceSnapshot() -> PersistenceSnapshot {
        PersistenceSnapshot(
            schemaVersion: 1,
            rowLimit: rowLimit,
            segmentSize: segmentSize,
            retainedRowSummary: retainedRowSummary,
            segments: persistenceSegmentDescriptors()
        )
    }

    static func exportWindowSummary(
        absoluteStartIndex: Int,
        rowCount: Int,
        materializationLimit: Int,
        retainedRowSummary: RetainedRowSummary
    ) -> ExportWindowSummary {
        let requestedRowCount = max(0, rowCount)
        let materializationLimit = max(0, materializationLimit)
        let requestedEndIndex = clampedEndIndex(
            startIndex: absoluteStartIndex,
            count: requestedRowCount
        )
        let retainedEndIndex = retainedRowSummary.nextRowIndex

        let firstAvailableIndex = max(
            absoluteStartIndex,
            retainedRowSummary.firstRetainedRowIndex
        )
        let unavailableEndIndex = min(
            requestedEndIndex,
            retainedRowSummary.firstRetainedRowIndex
        )
        let skippedDroppedRowCount = clampedNonNegativeDistance(
            from: absoluteStartIndex,
            to: unavailableEndIndex
        )

        let availableEndIndex = min(requestedEndIndex, retainedEndIndex)
        let availableRowCount = clampedNonNegativeDistance(
            from: firstAvailableIndex,
            to: availableEndIndex
        )
        let skippedFutureRowCount = clampedNonNegativeDistance(
            from: max(absoluteStartIndex, retainedEndIndex),
            to: requestedEndIndex
        )

        return ExportWindowSummary(
            requestedStartAbsoluteRowIndex: absoluteStartIndex,
            requestedRowCount: requestedRowCount,
            firstAvailableAbsoluteRowIndex: availableRowCount > 0 ? firstAvailableIndex : nil,
            availableRowCount: availableRowCount,
            boundedMaterializedRowCount: min(availableRowCount, materializationLimit),
            materializationLimit: materializationLimit,
            skippedDroppedRowCount: skippedDroppedRowCount,
            skippedFutureRowCount: skippedFutureRowCount,
            retainedRowSummary: retainedRowSummary
        )
    }

    static func liveAccessSummary(
        purpose: LiveAccessPurpose,
        absoluteStartIndex: Int,
        rowCount: Int,
        materializationLimit: Int,
        retainedRowSummary: RetainedRowSummary
    ) -> LiveAccessSummary {
        let exportWindow = exportWindowSummary(
            absoluteStartIndex: absoluteStartIndex,
            rowCount: rowCount,
            materializationLimit: materializationLimit,
            retainedRowSummary: retainedRowSummary
        )
        return LiveAccessSummary(
            purpose: purpose,
            exportWindow: exportWindow,
            availability: liveAccessAvailability(for: exportWindow)
        )
    }

    private static func liveAccessAvailability(for summary: ExportWindowSummary) -> LiveAccessAvailability {
        guard summary.requestedRowCount > 0 else {
            return .emptyRequest
        }

        let hasAvailableRows = summary.availableRowCount > 0
        let hasDroppedRows = summary.skippedDroppedRowCount > 0
        let hasFutureRows = summary.skippedFutureRowCount > 0

        switch (hasAvailableRows, hasDroppedRows, hasFutureRows) {
        case (true, false, false):
            return .fullyAvailable
        case (false, true, false):
            return .fullyDropped
        case (false, false, true):
            return .fullyFuture
        case (_, true, true):
            return .partiallyDroppedAndFuture
        case (_, true, false):
            return .partiallyDropped
        case (_, false, true):
            return .partiallyFuture
        case (false, false, false):
            return .emptyRequest
        }
    }

    private var retainedStorageRowCount: Int {
        guard firstRetainedSegmentIndex < segments.count else { return 0 }
        return segments[firstRetainedSegmentIndex...].reduce(0) { $0 + $1.count }
    }

    private var retainedSegmentCount: Int {
        max(0, segments.count - firstRetainedSegmentIndex)
    }

    private var maximumRetainedSegmentCount: Int {
        guard rowLimit > 0 else { return 0 }
        return Int((rowLimit + segmentSize - 1) / segmentSize) + 1
    }

    private var maximumBackingSegmentCount: Int {
        maximumRetainedSegmentCount * 4
    }

    private var maximumRetainedStorageRowCount: Int {
        guard rowLimit > 0 else { return 0 }
        return rowLimit + segmentSize - 1
    }

    private static func clampedEndIndex(startIndex: Int, count: Int) -> Int {
        guard count > 0 else { return startIndex }
        let (endIndex, overflow) = startIndex.addingReportingOverflow(count)
        return overflow ? Int.max : endIndex
    }

    private static func clampedNonNegativeDistance(from startIndex: Int, to endIndex: Int) -> Int {
        guard endIndex > startIndex else { return 0 }
        let (distance, overflow) = endIndex.subtractingReportingOverflow(startIndex)
        return overflow ? Int.max : distance
    }

    private func persistenceSegmentDescriptors() -> [PersistenceSegmentDescriptor] {
        var descriptors: [PersistenceSegmentDescriptor] = []
        descriptors.reserveCapacity(segments.count)

        var nextAbsoluteRowIndex = droppedRowCount
        for segmentIndex in segments.indices {
            let segment = segments[segmentIndex]
            let visibleStartOffset = segmentIndex == segments.startIndex ? firstSegmentStartIndex : 0
            let visibleRowCount = segment.count - visibleStartOffset
            guard visibleRowCount > 0 else { continue }

            descriptors.append(.init(
                ordinal: descriptors.count,
                absoluteStartRowIndex: nextAbsoluteRowIndex,
                visibleRowCount: visibleRowCount,
                retainedStorageRowCount: segment.count,
                isFirstPartialSegment: segmentIndex == segments.startIndex && visibleStartOffset > 0,
                isMutableTailSegment: segmentIndex == segments.index(before: segments.endIndex) &&
                    segment.count < segmentSize
            ))
            nextAbsoluteRowIndex += visibleRowCount
        }

        return descriptors
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
            firstRetainedSegmentIndex = 0
            firstSegmentStartIndex = 0
            visibleRowCount = 0
            compactionCount += 1
            return
        }

        var remainingRowsToDrop = rowsToDrop
        while remainingRowsToDrop > 0, firstRetainedSegmentIndex < segments.count {
            let visibleRowsInFirstSegment = segments[firstRetainedSegmentIndex].count - firstSegmentStartIndex
            if remainingRowsToDrop < visibleRowsInFirstSegment {
                firstSegmentStartIndex += remainingRowsToDrop
                visibleRowCount -= remainingRowsToDrop
                remainingRowsToDrop = 0
            } else {
                remainingRowsToDrop -= visibleRowsInFirstSegment
                visibleRowCount -= visibleRowsInFirstSegment
                firstRetainedSegmentIndex += 1
                firstSegmentStartIndex = 0
            }
        }
    }

    private mutating func compactSegmentsIfNeeded() {
        guard firstRetainedSegmentIndex < segments.count else {
            segments.removeAll(keepingCapacity: false)
            firstRetainedSegmentIndex = 0
            firstSegmentStartIndex = 0
            return
        }
        guard retainedSegmentCount > maximumRetainedSegmentCount ||
            retainedStorageRowCount > maximumRetainedStorageRowCount ||
            segments.count > maximumBackingSegmentCount
        else {
            return
        }

        let visibleRows = (0..<visibleRowCount).map { row(at: $0)! }
        segments = []
        firstRetainedSegmentIndex = 0
        firstSegmentStartIndex = 0
        for row in visibleRows {
            appendWithoutTrimming(row)
        }
        visibleRowCount = visibleRows.count
        compactionCount += 1
    }
}
