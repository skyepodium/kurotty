import KurottyCore

struct BoundedScrollbackRows {
    struct Diagnostics: Equatable {
        let limit: Int
        let visibleRowCount: Int
        let retainedStorageRowCount: Int
        let droppedRowCount: Int
        let compactionCount: Int
        let pressureLevel: PressureLevel
    }

    enum PressureLevel: Equatable {
        case empty
        case low
        case elevated
        case high
        case saturated
    }

    private var storage: [[TerminalScreenCell]] = []
    private var startIndex = 0
    private var lastLimit = 0
    private var droppedRowCount = 0
    private var compactionCount = 0

    var count: Int {
        storage.count - startIndex
    }

    var isEmpty: Bool {
        count == 0
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            limit: lastLimit,
            visibleRowCount: count,
            retainedStorageRowCount: storage.count,
            droppedRowCount: droppedRowCount,
            compactionCount: compactionCount,
            pressureLevel: pressureLevel(visibleCount: count, limit: lastLimit)
        )
    }

    @discardableResult
    mutating func append(contentsOf newRows: [[TerminalScreenCell]], limit: Int) -> Int {
        guard !newRows.isEmpty else { return 0 }
        storage.append(contentsOf: newRows)
        let previousCount = count - newRows.count
        _ = trim(to: limit)
        return max(0, count - max(0, previousCount))
    }

    @discardableResult
    mutating func trim(to limit: Int) -> Bool {
        let boundedLimit = max(0, limit)
        lastLimit = boundedLimit
        let rowsToDrop = count - boundedLimit
        guard rowsToDrop > 0 else {
            compactStorageIfNeeded()
            return false
        }

        startIndex += rowsToDrop
        droppedRowCount += rowsToDrop
        compactStorageIfNeeded()
        return true
    }

    func row(at index: Int) -> [TerminalScreenCell]? {
        guard index >= 0, index < count else { return nil }
        return storage[startIndex + index]
    }

    mutating func remapStyle(from previousStyle: TerminalTextStyle, to nextStyle: TerminalTextStyle) {
        guard previousStyle != nextStyle else { return }
        for rowIndex in startIndex..<storage.count {
            for columnIndex in storage[rowIndex].indices where storage[rowIndex][columnIndex].style == previousStyle {
                storage[rowIndex][columnIndex].style = nextStyle
            }
        }
    }

    mutating func remapColors(_ colorMap: TerminalStyleColorMap) {
        for rowIndex in startIndex..<storage.count {
            for columnIndex in storage[rowIndex].indices {
                storage[rowIndex][columnIndex].style = storage[rowIndex][columnIndex].style.remappingColors(colorMap)
            }
        }
    }

    private mutating func compactStorageIfNeeded() {
        guard startIndex > 0 else { return }
        guard startIndex >= storage.count / 2 || startIndex == storage.count else { return }
        storage.removeSubrange(0..<startIndex)
        startIndex = 0
        compactionCount += 1
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
}
