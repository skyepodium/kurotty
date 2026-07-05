import KurottyCore

struct BoundedScrollbackRows {
    struct Diagnostics: Equatable {
        let limit: Int
        let visibleRowCount: Int
        let retainedStorageRowCount: Int
        let droppedRowCount: Int
        let compactionCount: Int
        let pressureLevel: PressureLevel
        let retainedRowSummary: SegmentedScrollbackStore<[TerminalScreenCell]>.RetainedRowSummary

        init(
            limit: Int,
            visibleRowCount: Int,
            retainedStorageRowCount: Int,
            droppedRowCount: Int,
            compactionCount: Int,
            pressureLevel: PressureLevel,
            retainedRowSummary: SegmentedScrollbackStore<[TerminalScreenCell]>.RetainedRowSummary = .init(
                firstRetainedRowIndex: 0,
                retainedRowCount: 0,
                droppedRowCount: 0
            )
        ) {
            self.limit = limit
            self.visibleRowCount = visibleRowCount
            self.retainedStorageRowCount = retainedStorageRowCount
            self.droppedRowCount = droppedRowCount
            self.compactionCount = compactionCount
            self.pressureLevel = pressureLevel
            self.retainedRowSummary = retainedRowSummary
        }
    }

    enum PressureLevel: Equatable {
        case empty
        case low
        case elevated
        case high
        case saturated
    }

    struct LiveReadWindowDescriptor: Equatable, CustomStringConvertible {
        let accessSummary: SegmentedScrollbackStore<[TerminalScreenCell]>.LiveAccessSummary
        let firstAvailableVisibleRowIndex: Int?
        let availableVisibleRowCount: Int
        let boundedMaterializedVisibleRowCount: Int

        var purpose: SegmentedScrollbackStore<[TerminalScreenCell]>.LiveAccessPurpose {
            accessSummary.purpose
        }

        var availability: SegmentedScrollbackStore<[TerminalScreenCell]>.LiveAccessAvailability {
            accessSummary.availability
        }

        var canServeSynchronously: Bool {
            accessSummary.canServeSynchronously
        }

        var requiresUserVisibleWarning: Bool {
            accessSummary.requiresUserVisibleWarning
        }

        var description: String {
            [
                "purpose=\(purpose)",
                "availability=\(availability)",
                "firstAvailableVisibleRow=\(firstAvailableVisibleRowIndex.map(String.init) ?? "none")",
                "availableVisibleRows=\(availableVisibleRowCount)",
                "boundedMaterializedVisibleRows=\(boundedMaterializedVisibleRowCount)",
                "canServeSynchronously=\(canServeSynchronously)",
                "requiresUserVisibleWarning=\(requiresUserVisibleWarning)",
                "access=\(accessSummary)",
            ].joined(separator: " ")
        }
    }

    private static let segmentSize = 1_024

    private var storage = Self.makeStorage(rowLimit: 0)
    private var droppedRowCountBaseline = 0
    private var compactionCountBaseline = 0

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    var diagnostics: Diagnostics {
        let storageDiagnostics = storage.diagnostics
        let retainedRowSummary = retainedRowSummary(
            storageDiagnostics: storageDiagnostics
        )
        return Diagnostics(
            limit: storageDiagnostics.rowLimit,
            visibleRowCount: storageDiagnostics.visibleRowCount,
            retainedStorageRowCount: storageDiagnostics.retainedStorageRowCount,
            droppedRowCount: droppedRowCountBaseline + storageDiagnostics.droppedRowCount,
            compactionCount: compactionCountBaseline + storageDiagnostics.compactionCount,
            pressureLevel: pressureLevel(
                visibleCount: storageDiagnostics.visibleRowCount,
                limit: storageDiagnostics.rowLimit
            ),
            retainedRowSummary: retainedRowSummary
        )
    }

    var retainedRowSummary: SegmentedScrollbackStore<[TerminalScreenCell]>.RetainedRowSummary {
        retainedRowSummary(storageDiagnostics: storage.diagnostics)
    }

    @discardableResult
    mutating func append(contentsOf newRows: [[TerminalScreenCell]], limit: Int) -> Int {
        guard !newRows.isEmpty else { return 0 }
        _ = storage.trim(to: limit)
        return storage.append(contentsOf: newRows)
    }

    @discardableResult
    mutating func trim(to limit: Int) -> Bool {
        storage.trim(to: limit)
    }

    func row(at index: Int) -> [TerminalScreenCell]? {
        storage.row(at: index)
    }

    func absoluteRowIndex(forVisibleRowIndex visibleRowIndex: Int) -> Int? {
        guard visibleRowIndex >= 0, visibleRowIndex < storage.count else {
            return nil
        }
        return retainedRowSummary.firstRetainedRowIndex + visibleRowIndex
    }

    func visibleRowIndex(forAbsoluteRowIndex absoluteRowIndex: Int) -> Int? {
        guard retainedRowSummary.contains(absoluteRowIndex: absoluteRowIndex) else {
            return nil
        }
        return absoluteRowIndex - retainedRowSummary.firstRetainedRowIndex
    }

    func exportWindowSummary(
        absoluteStartIndex: Int,
        rowCount: Int,
        materializationLimit: Int
    ) -> SegmentedScrollbackStore<[TerminalScreenCell]>.ExportWindowSummary {
        SegmentedScrollbackStore<[TerminalScreenCell]>.exportWindowSummary(
            absoluteStartIndex: absoluteStartIndex,
            rowCount: rowCount,
            materializationLimit: materializationLimit,
            retainedRowSummary: retainedRowSummary
        )
    }

    func liveReadWindowDescriptor(
        purpose: SegmentedScrollbackStore<[TerminalScreenCell]>.LiveAccessPurpose,
        absoluteStartIndex: Int,
        rowCount: Int,
        materializationLimit: Int
    ) -> LiveReadWindowDescriptor {
        let accessSummary = SegmentedScrollbackStore<[TerminalScreenCell]>.liveAccessSummary(
            purpose: purpose,
            absoluteStartIndex: absoluteStartIndex,
            rowCount: rowCount,
            materializationLimit: materializationLimit,
            retainedRowSummary: retainedRowSummary
        )
        let exportWindow = accessSummary.exportWindow
        let firstAvailableVisibleRowIndex = exportWindow.firstAvailableAbsoluteRowIndex.flatMap {
            visibleRowIndex(forAbsoluteRowIndex: $0)
        }

        return LiveReadWindowDescriptor(
            accessSummary: accessSummary,
            firstAvailableVisibleRowIndex: firstAvailableVisibleRowIndex,
            availableVisibleRowCount: exportWindow.availableRowCount,
            boundedMaterializedVisibleRowCount: exportWindow.boundedMaterializedRowCount
        )
    }

    mutating func remapStyle(from previousStyle: TerminalTextStyle, to nextStyle: TerminalTextStyle) {
        guard previousStyle != nextStyle else { return }
        remapRows { row in
            for columnIndex in row.indices where row[columnIndex].style == previousStyle {
                row[columnIndex].style = nextStyle
            }
        }
    }

    mutating func remapColors(_ colorMap: TerminalStyleColorMap) {
        remapRows { row in
            for columnIndex in row.indices {
                row[columnIndex].style = row[columnIndex].style.remappingColors(colorMap)
            }
        }
    }

    private mutating func compactStorageIfNeeded() {
        _ = storage.trim(to: storage.diagnostics.rowLimit)
    }

    private mutating func remapRows(_ transform: (inout [TerminalScreenCell]) -> Void) {
        let previousDiagnostics = storage.diagnostics
        let remappedRows = (0..<storage.count).compactMap { index -> [TerminalScreenCell]? in
            guard var row = storage.row(at: index) else { return nil }
            transform(&row)
            return row
        }

        droppedRowCountBaseline += previousDiagnostics.droppedRowCount
        compactionCountBaseline += previousDiagnostics.compactionCount
        storage = Self.makeStorage(rowLimit: previousDiagnostics.rowLimit)
        _ = storage.append(contentsOf: remappedRows)
    }

    private func pressureLevel(visibleCount: Int, limit: Int) -> PressureLevel {
        guard limit > 0 else { return .empty }
        guard visibleCount > 0 else { return .empty }
        if visibleCount >= limit {
            return .saturated
        }
        let ratio = Double(visibleCount) / Double(limit)
        if ratio >= 0.8 {
            return .high
        }
        if ratio >= 0.5 {
            return .elevated
        }
        return .low
    }

    private func retainedRowSummary(
        storageDiagnostics: SegmentedScrollbackStore<[TerminalScreenCell]>.Diagnostics
    ) -> SegmentedScrollbackStore<[TerminalScreenCell]>.RetainedRowSummary {
        let droppedRowCount = droppedRowCountBaseline + storageDiagnostics.droppedRowCount
        return .init(
            firstRetainedRowIndex: droppedRowCount,
            retainedRowCount: storageDiagnostics.visibleRowCount,
            droppedRowCount: droppedRowCount
        )
    }

    private static func makeStorage(rowLimit: Int) -> SegmentedScrollbackStore<[TerminalScreenCell]> {
        SegmentedScrollbackStore(rowLimit: rowLimit, segmentSize: segmentSize)
    }
}
