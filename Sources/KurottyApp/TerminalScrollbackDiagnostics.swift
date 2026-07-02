struct TerminalScrollbackDiagnosticsSummary: Equatable, CustomStringConvertible {
    enum Status: String, Equatable {
        case empty
        case healthy
        case elevated
        case nearCapacity
        case full
        case droppingRows
    }

    let capacity: Int
    let retainedRowCount: Int
    let retainedStorageRowCount: Int
    let firstRetainedRowIndex: Int
    let lastRetainedRowIndex: Int?
    let nextRowIndex: Int
    let droppedRowCount: Int
    let compactionCount: Int
    let pressureLevel: BoundedScrollbackRows.PressureLevel
    let status: Status

    init(_ diagnostics: BoundedScrollbackRows.Diagnostics) {
        capacity = diagnostics.limit
        retainedRowCount = diagnostics.visibleRowCount
        retainedStorageRowCount = diagnostics.retainedStorageRowCount
        firstRetainedRowIndex = diagnostics.retainedRowSummary.firstRetainedRowIndex
        lastRetainedRowIndex = diagnostics.retainedRowSummary.lastRetainedRowIndex
        nextRowIndex = diagnostics.retainedRowSummary.nextRowIndex
        droppedRowCount = diagnostics.droppedRowCount
        compactionCount = diagnostics.compactionCount
        pressureLevel = diagnostics.pressureLevel
        status = Self.status(
            pressureLevel: diagnostics.pressureLevel,
            droppedRowCount: diagnostics.droppedRowCount
        )
    }

    var description: String {
        [
            "capacity=\(capacity)",
            "retainedRows=\(retainedRowCount)",
            "retainedStorageRows=\(retainedStorageRowCount)",
            "firstRetainedRow=\(firstRetainedRowIndex)",
            "lastRetainedRow=\(lastRetainedRowIndex.map(String.init) ?? "none")",
            "nextRow=\(nextRowIndex)",
            "droppedRows=\(droppedRowCount)",
            "compactions=\(compactionCount)",
            "pressure=\(pressureLevel)",
            "status=\(status.rawValue)",
        ].joined(separator: " ")
    }

    private static func status(
        pressureLevel: BoundedScrollbackRows.PressureLevel,
        droppedRowCount: Int
    ) -> Status {
        if droppedRowCount > 0 {
            return .droppingRows
        }

        switch pressureLevel {
        case .empty:
            return .empty
        case .low:
            return .healthy
        case .elevated:
            return .elevated
        case .high:
            return .nearCapacity
        case .saturated:
            return .full
        }
    }
}
