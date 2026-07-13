import Foundation
import KurottyCore

struct TerminalSearchMatch: Hashable, Sendable {
    let row: Int
    let startColumn: Int
    let endColumn: Int

    func contains(row: Int, column: Int) -> Bool {
        self.row == row && column >= startColumn && column < endColumn
    }
}

enum TerminalSearchHighlightKind: Equatable {
    case match
    case current
}

struct TerminalSearchResults: Sendable {
    static let empty = TerminalSearchResults(matches: [])

    let matches: [TerminalSearchMatch]
    let isTruncated: Bool
    private let matchIndexRangesByRow: [Int: Range<Int>]

    init(matches: [TerminalSearchMatch], isTruncated: Bool = false) {
        self.matches = matches.sorted {
            ($0.row, $0.startColumn, $0.endColumn) < ($1.row, $1.startColumn, $1.endColumn)
        }
        self.isTruncated = isTruncated

        var ranges: [Int: Range<Int>] = [:]
        var rangeStart = 0
        while rangeStart < self.matches.count {
            let row = self.matches[rangeStart].row
            var rangeEnd = rangeStart + 1
            while rangeEnd < self.matches.count, self.matches[rangeEnd].row == row {
                rangeEnd += 1
            }
            ranges[row] = rangeStart..<rangeEnd
            rangeStart = rangeEnd
        }
        matchIndexRangesByRow = ranges
    }

    func highlight(
        at position: TerminalCellPosition,
        currentMatch: TerminalSearchMatch?
    ) -> TerminalSearchHighlightKind? {
        guard let matchRange = matchIndexRangesByRow[position.row],
              let matchIndex = matchRange.first(where: {
                  matches[$0].contains(row: position.row, column: position.column)
              })
        else {
            return nil
        }
        let match = matches[matchIndex]
        return match == currentMatch ? .current : .match
    }
}

struct TerminalSearchSummary: Equatable, Sendable {
    static let empty = TerminalSearchSummary(currentIndex: nil, totalMatches: 0)

    let currentIndex: Int?
    let totalMatches: Int
    let isTruncated: Bool

    init(currentIndex: Int?, totalMatches: Int, isTruncated: Bool = false) {
        self.currentIndex = currentIndex
        self.totalMatches = totalMatches
        self.isTruncated = isTruncated
    }

    var displayText: String {
        guard let currentIndex, totalMatches > 0 else {
            return "0/0"
        }
        return "\(currentIndex + 1)/\(totalMatches)\(isTruncated ? "+" : "")"
    }
}

struct TerminalSearchSnapshot: Sendable {
    let scrollbackRows: BoundedScrollbackRows
    let screenRows: [[TerminalScreenCell]]
    let preferredStartRow: Int

    init(
        scrollbackRows: BoundedScrollbackRows,
        screenRows: [[TerminalScreenCell]],
        preferredStartRow: Int = 0
    ) {
        self.scrollbackRows = scrollbackRows
        self.screenRows = screenRows
        self.preferredStartRow = preferredStartRow
    }

    var rowCount: Int {
        scrollbackRows.count + screenRows.count
    }

    func row(at index: Int) -> [TerminalScreenCell]? {
        guard index >= 0 else { return nil }
        if index < scrollbackRows.count {
            return scrollbackRows.row(at: index)
        }
        let screenIndex = index - scrollbackRows.count
        guard screenRows.indices.contains(screenIndex) else { return nil }
        return screenRows[screenIndex]
    }
}

struct TerminalSearchScanResult: Sendable {
    static let empty = TerminalSearchScanResult(matches: [], isTruncated: false)

    let matches: [TerminalSearchMatch]
    let isTruncated: Bool
}

enum TerminalSearchMatcher {
    static func findAll(
        query: String,
        in rows: [[TerminalScreenCell]]
    ) -> [TerminalSearchMatch] {
        findAll(
            query: query,
            in: TerminalSearchSnapshot(
                scrollbackRows: BoundedScrollbackRows(),
                screenRows: rows
            )
        )
    }

    static func findAll(
        query: String,
        in snapshot: TerminalSearchSnapshot
    ) -> [TerminalSearchMatch] {
        scan(query: query, in: snapshot).matches
    }

    static func scan(
        query: String,
        in snapshot: TerminalSearchSnapshot,
        maximumMatchCount: Int = AppConstants.Terminal.maximumSearchMatchCount
    ) -> TerminalSearchScanResult {
        guard !query.isEmpty, maximumMatchCount > 0, snapshot.rowCount > 0 else {
            return .empty
        }

        var matches: [TerminalSearchMatch] = []
        matches.reserveCapacity(min(maximumMatchCount, 1_024))
        let startRow = max(0, min(snapshot.rowCount - 1, snapshot.preferredStartRow))
        let searchRanges = [startRow..<snapshot.rowCount, 0..<startRow]
        var isTruncated = false

        searchLoop: for rowRange in searchRanges {
            for rowIndex in rowRange {
                if Task.isCancelled {
                    return .empty
                }
                guard let cells = snapshot.row(at: rowIndex) else { continue }
                let rowMatches = matchesInRow(cells, row: rowIndex, query: query)
                let remainingCapacity = maximumMatchCount - matches.count
                if remainingCapacity == 0 {
                    guard rowMatches.isEmpty else {
                        isTruncated = true
                        break searchLoop
                    }
                    continue
                }
                guard rowMatches.count <= remainingCapacity else {
                    matches.append(contentsOf: rowMatches.prefix(remainingCapacity))
                    isTruncated = true
                    break searchLoop
                }
                matches.append(contentsOf: rowMatches)
            }
        }
        matches.sort {
            ($0.row, $0.startColumn, $0.endColumn) < ($1.row, $1.startColumn, $1.endColumn)
        }
        return TerminalSearchScanResult(matches: matches, isTruncated: isTruncated)
    }

    private static func matchesInRow(
        _ cells: [TerminalScreenCell],
        row: Int,
        query: String
    ) -> [TerminalSearchMatch] {
        guard let lastContentColumn = cells.lastIndex(where: {
            !$0.isContinuation && !$0.character.isWhitespace
        }) else {
            return []
        }

        var text = ""
        var startColumnByUTF16Unit: [Int] = []
        var endColumnByUTF16Unit: [Int] = []
        for column in cells.indices where column <= lastContentColumn {
            let cell = cells[column]
            guard !cell.isContinuation else { continue }
            text.append(cell.character)
            let utf16UnitCount = String(cell.character).utf16.count
            startColumnByUTF16Unit.append(contentsOf: repeatElement(column, count: utf16UnitCount))
            endColumnByUTF16Unit.append(contentsOf: repeatElement(
                column + max(1, cell.character.terminalColumnWidth),
                count: utf16UnitCount
            ))
        }
        let searchableText = text as NSString
        guard searchableText.length > 0,
              searchableText.length == startColumnByUTF16Unit.count,
              searchableText.length == endColumnByUTF16Unit.count
        else {
            return []
        }

        var results: [TerminalSearchMatch] = []
        var searchRange = NSRange(location: 0, length: searchableText.length)
        while searchRange.length > 0 {
            let matchRange = searchableText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard matchRange.location != NSNotFound, matchRange.length > 0 else { break }
            let finalUTF16Unit = NSMaxRange(matchRange) - 1
            guard startColumnByUTF16Unit.indices.contains(matchRange.location),
                  endColumnByUTF16Unit.indices.contains(finalUTF16Unit)
            else {
                break
            }

            results.append(TerminalSearchMatch(
                row: row,
                startColumn: startColumnByUTF16Unit[matchRange.location],
                endColumn: endColumnByUTF16Unit[finalUTF16Unit]
            ))
            let nextLocation = NSMaxRange(matchRange)
            searchRange = NSRange(
                location: nextLocation,
                length: searchableText.length - nextLocation
            )
        }
        return results
    }
}

enum TerminalSearchNavigation {
    static func preferredInitialIndex(
        matches: [TerminalSearchMatch],
        visibleRows: Range<Int>
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        let visibleEndRow = max(visibleRows.lowerBound, visibleRows.upperBound - 1)
        return matches.lastIndex(where: { $0.row <= visibleEndRow }) ?? 0
    }

    static func movedIndex(
        from currentIndex: Int?,
        by delta: Int,
        matchCount: Int
    ) -> Int? {
        guard matchCount > 0 else { return nil }
        let currentIndex = currentIndex ?? (delta >= 0 ? -1 : 0)
        let remainder = (currentIndex + delta) % matchCount
        return remainder >= 0 ? remainder : remainder + matchCount
    }

    static func scrollbackOffsetToReveal(
        row: Int,
        contentRowCount: Int,
        visibleRowCount: Int,
        currentOffset: Int
    ) -> Int {
        let visibleRowCount = max(1, visibleRowCount)
        let bottomStart = max(0, contentRowCount - visibleRowCount)
        let currentOffset = max(0, min(bottomStart, currentOffset))
        let currentStart = bottomStart - currentOffset
        let clampedRow = max(0, min(max(0, contentRowCount - 1), row))

        let targetStart: Int
        if clampedRow < currentStart {
            targetStart = clampedRow
        } else if clampedRow >= currentStart + visibleRowCount {
            targetStart = clampedRow - visibleRowCount + 1
        } else {
            targetStart = currentStart
        }
        return bottomStart - max(0, min(bottomStart, targetStart))
    }
}

enum TerminalSearchStyle {
    static let matchBackgroundColor = SIMD4<Float>(0.93, 0.78, 0.32, 1)
    static let currentBackgroundColor = SIMD4<Float>(0.94, 0.48, 0.26, 1)
    static let foregroundColor = SIMD4<Float>(0.10, 0.10, 0.11, 1)
}
