import Foundation
import KurottyCore

/// What the user can flip from the search bar. Diacritic insensitivity is not
/// among them: it stays on for literal queries, because folding "café" onto
/// "cafe" is the helpful kind of leniency, where case folding is the kind
/// people want to turn off.
struct TerminalSearchOptions: Equatable, Sendable {
    static let `default` = TerminalSearchOptions()

    var isCaseSensitive: Bool = false
    var usesRegularExpression: Bool = false
}

/// One match. A match that crosses a soft wrap stays one match — the count in
/// the bar and Return-to-advance both mean "logical match", not "row fragment"
/// — and `contains` is what spreads its highlight over the rows it covers.
struct TerminalSearchMatch: Hashable, Sendable {
    let row: Int
    let startColumn: Int
    let endRow: Int
    let endColumn: Int

    init(row: Int, startColumn: Int, endColumn: Int) {
        self.init(row: row, startColumn: startColumn, endRow: row, endColumn: endColumn)
    }

    init(row: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        self.row = row
        self.startColumn = startColumn
        self.endRow = max(row, endRow)
        self.endColumn = endColumn
    }

    var rows: ClosedRange<Int> { row...endRow }

    /// A row a soft-wrapped match passes through is full by construction — the
    /// row filled up, which is why it wrapped — so every column past the start
    /// on the first row, and before the end on the last, is inside the match.
    func contains(row: Int, column: Int) -> Bool {
        guard rows.contains(row) else { return false }
        if row == self.row, column < startColumn { return false }
        if row == endRow, column >= endColumn { return false }
        return true
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
    private let matchIndicesByRow: [Int: [Int]]

    init(matches: [TerminalSearchMatch], isTruncated: Bool = false) {
        self.matches = matches.sorted {
            ($0.row, $0.startColumn, $0.endRow, $0.endColumn)
                < ($1.row, $1.startColumn, $1.endRow, $1.endColumn)
        }
        self.isTruncated = isTruncated

        // A wrapped match paints rows its `row` does not name, so the row index
        // has to list it under every row it covers. Two matches on one row need
        // not be adjacent in `matches` either, once a wrapped one starts above.
        var indicesByRow: [Int: [Int]] = [:]
        for (matchIndex, match) in self.matches.enumerated() {
            for row in match.rows {
                indicesByRow[row, default: []].append(matchIndex)
            }
        }
        matchIndicesByRow = indicesByRow
    }

    func highlight(
        at position: TerminalCellPosition,
        currentMatch: TerminalSearchMatch?
    ) -> TerminalSearchHighlightKind? {
        guard let matchIndices = matchIndicesByRow[position.row],
              let matchIndex = matchIndices.first(where: {
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

/// A query compiled against the options it was typed under. Compiling once per
/// scan rather than once per line is what keeps regex affordable, and it gives
/// the search bar a cheap way to ask whether what the user typed parses at all.
struct TerminalSearchPattern {
    private enum Kind {
        case literal(NSString.CompareOptions)
        case regularExpression(NSRegularExpression)
    }

    private let query: String
    private let kind: Kind

    /// `nil` for an empty query or a regex that does not compile. Half a
    /// pattern — `(foo` between two keystrokes — is ordinary input, not an
    /// error, so it matches nothing until it parses instead of throwing.
    init?(query: String, options: TerminalSearchOptions = .default) {
        guard !query.isEmpty else { return nil }
        self.query = query
        if options.usesRegularExpression {
            let regularExpressionOptions: NSRegularExpression.Options =
                options.isCaseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(
                pattern: query,
                options: regularExpressionOptions
            ) else {
                return nil
            }
            kind = .regularExpression(expression)
        } else {
            var compareOptions: NSString.CompareOptions = [.diacriticInsensitive]
            if !options.isCaseSensitive {
                compareOptions.insert(.caseInsensitive)
            }
            kind = .literal(compareOptions)
        }
    }

    /// Whether the bar should render the query as typed-but-unusable. An empty
    /// query is not invalid, it is unstarted.
    static func isValidQuery(_ query: String, options: TerminalSearchOptions) -> Bool {
        query.isEmpty || TerminalSearchPattern(query: query, options: options) != nil
    }

    /// Non-overlapping matches in document order.
    func matchRanges(in text: String) -> [NSRange] {
        let searchableText = text as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < searchableText.length {
            guard let range = firstMatch(in: searchableText, from: location) else { break }
            // A zero-width regex match (`a*` against `bbb`) names a position,
            // not text. There is nothing to highlight, and stopping at the
            // first one would hide the real matches behind it, so step past.
            guard range.length > 0 else {
                location = max(range.location, location) + 1
                continue
            }
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }

    private func firstMatch(in searchableText: NSString, from location: Int) -> NSRange? {
        let searchRange = NSRange(
            location: location,
            length: searchableText.length - location
        )
        switch kind {
        case let .literal(compareOptions):
            let range = searchableText.range(
                of: query,
                options: compareOptions,
                range: searchRange
            )
            return range.location == NSNotFound ? nil : range
        case let .regularExpression(expression):
            return expression.firstMatch(
                in: searchableText as String,
                options: [],
                range: searchRange
            )?.range
        }
    }
}

enum TerminalSearchMatcher {
    /// Where one UTF-16 unit of a joined logical line sits on screen.
    private struct CellAnchor {
        let row: Int
        let startColumn: Int
        let endColumn: Int
    }

    static func findAll(
        query: String,
        options: TerminalSearchOptions = .default,
        in rows: [[TerminalScreenCell]]
    ) -> [TerminalSearchMatch] {
        findAll(
            query: query,
            options: options,
            in: TerminalSearchSnapshot(
                scrollbackRows: BoundedScrollbackRows(),
                screenRows: rows
            )
        )
    }

    static func findAll(
        query: String,
        options: TerminalSearchOptions = .default,
        in snapshot: TerminalSearchSnapshot
    ) -> [TerminalSearchMatch] {
        scan(query: query, options: options, in: snapshot).matches
    }

    static func scan(
        query: String,
        options: TerminalSearchOptions = .default,
        in snapshot: TerminalSearchSnapshot,
        maximumMatchCount: Int = AppConstants.Terminal.maximumSearchMatchCount,
        maximumWrappedRowJoinCount: Int = AppConstants.Terminal.maximumSearchWrappedRowJoinCount
    ) -> TerminalSearchScanResult {
        guard let pattern = TerminalSearchPattern(query: query, options: options),
              maximumMatchCount > 0,
              snapshot.rowCount > 0
        else {
            return .empty
        }

        var matches: [TerminalSearchMatch] = []
        matches.reserveCapacity(min(maximumMatchCount, 1_024))
        // The two ranges are disjoint and both begin on a logical-line boundary:
        // row 0 always starts one, and the anchor is walked back to the top of
        // whatever line the viewport happens to open in the middle of.
        let startRow = max(0, min(snapshot.rowCount - 1, snapshot.preferredStartRow))
        let anchorRow = logicalLineStartRow(
            containing: startRow,
            in: snapshot,
            maximumWalkBackCount: maximumWrappedRowJoinCount
        )
        let searchRanges = [anchorRow..<snapshot.rowCount, 0..<anchorRow]
        var isTruncated = false

        searchLoop: for rowRange in searchRanges {
            var lineStartRow = rowRange.lowerBound
            while lineStartRow < rowRange.upperBound {
                var lineRows: [[TerminalScreenCell]] = []
                var nextRow = lineStartRow
                while nextRow < rowRange.upperBound {
                    if Task.isCancelled {
                        return .empty
                    }
                    guard let cells = snapshot.row(at: nextRow) else {
                        nextRow += 1
                        break
                    }
                    lineRows.append(cells)
                    nextRow += 1
                    guard cells.last?.wrapsToNextRow == true,
                          lineRows.count < maximumWrappedRowJoinCount
                    else {
                        break
                    }
                }
                let lineMatches = matchesInLogicalLine(
                    lineRows,
                    startingRow: lineStartRow,
                    pattern: pattern
                )
                lineStartRow = nextRow

                let remainingCapacity = maximumMatchCount - matches.count
                if remainingCapacity == 0 {
                    guard lineMatches.isEmpty else {
                        isTruncated = true
                        break searchLoop
                    }
                    continue
                }
                guard lineMatches.count <= remainingCapacity else {
                    matches.append(contentsOf: lineMatches.prefix(remainingCapacity))
                    isTruncated = true
                    break searchLoop
                }
                matches.append(contentsOf: lineMatches)
            }
        }
        matches.sort {
            ($0.row, $0.startColumn, $0.endRow, $0.endColumn)
                < ($1.row, $1.startColumn, $1.endRow, $1.endColumn)
        }
        return TerminalSearchScanResult(matches: matches, isTruncated: isTruncated)
    }

    /// First row of the logical line `row` belongs to. Only a soft wrap joins
    /// rows; a hard newline leaves `wrapsToNextRow` clear and ends the line.
    /// The walk back is bounded for the same reason the join is: a line can be
    /// as long as the scrollback, and this runs before any match is found.
    private static func logicalLineStartRow(
        containing row: Int,
        in snapshot: TerminalSearchSnapshot,
        maximumWalkBackCount: Int
    ) -> Int {
        var startRow = row
        while startRow > 0,
              row - startRow < maximumWalkBackCount,
              snapshot.row(at: startRow - 1)?.last?.wrapsToNextRow == true {
            startRow -= 1
        }
        return startRow
    }

    /// Matches a run of soft-wrapped rows as the single line the user sees. A
    /// grep hit or a stack frame that happens to land across a wrap is the
    /// common case, not an edge case, and matching row by row misses it
    /// silently — the worst failure a search can have.
    private static func matchesInLogicalLine(
        _ rows: [[TerminalScreenCell]],
        startingRow: Int,
        pattern: TerminalSearchPattern
    ) -> [TerminalSearchMatch] {
        var text = ""
        var anchorsByUTF16Unit: [CellAnchor] = []
        for (rowOffset, cells) in rows.enumerated() {
            let rowIndex = startingRow + rowOffset
            // Trailing blanks on the last row are padding, and matching them
            // would let " " hit every row on screen. A wrapped row has no
            // padding: it filled up, which is why it wrapped.
            let lastContentColumn: Int
            if rowOffset < rows.count - 1 {
                lastContentColumn = cells.count - 1
            } else if let lastWrittenColumn = cells.lastIndex(where: {
                !$0.isContinuation && !$0.character.isWhitespace
            }) {
                lastContentColumn = lastWrittenColumn
            } else {
                continue
            }

            for column in cells.indices where column <= lastContentColumn {
                let cell = cells[column]
                guard !cell.isContinuation else { continue }
                text.append(cell.character)
                anchorsByUTF16Unit.append(contentsOf: repeatElement(
                    CellAnchor(
                        row: rowIndex,
                        startColumn: column,
                        endColumn: column + max(1, cell.character.terminalColumnWidth)
                    ),
                    count: String(cell.character).utf16.count
                ))
            }
        }
        guard !anchorsByUTF16Unit.isEmpty,
              text.utf16.count == anchorsByUTF16Unit.count
        else {
            return []
        }

        var results: [TerminalSearchMatch] = []
        for range in pattern.matchRanges(in: text) {
            let finalUTF16Unit = NSMaxRange(range) - 1
            guard anchorsByUTF16Unit.indices.contains(range.location),
                  anchorsByUTF16Unit.indices.contains(finalUTF16Unit)
            else {
                break
            }
            // The two ends are the whole mapping: the rows they bracket are
            // covered in full, so a match spanning three rows needs no interior
            // bookkeeping to highlight the middle one.
            let start = anchorsByUTF16Unit[range.location]
            let end = anchorsByUTF16Unit[finalUTF16Unit]
            results.append(TerminalSearchMatch(
                row: start.row,
                startColumn: start.startColumn,
                endRow: end.row,
                endColumn: end.endColumn
            ))
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
