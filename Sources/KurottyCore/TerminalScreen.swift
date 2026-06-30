import Foundation

public struct TerminalScreen: Sendable {
    public private(set) var rows: Int
    public private(set) var columns: Int
    public var cells: [[TerminalScreenCell]]
    private var resizeHiddenRowsAbove: [[TerminalScreenCell]] = []
    private var resizeHiddenRowsBelow: [[TerminalScreenCell]] = []

    public init(rows: Int, columns: Int) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.cells = Array(repeating: TerminalScreen.blankRow(columns: self.columns), count: self.rows)
    }

    @discardableResult
    public mutating func resize(rows newRows: Int, columns newColumns: Int, anchorRow: Int? = nil) -> Int {
        let targetRows = max(1, newRows)
        let targetColumns = max(1, newColumns)
        let oldRows = resizeHiddenRowsAbove + cells + resizeHiddenRowsBelow
        let normalizedRows = oldRows.map { TerminalScreen.resize(row: $0, columns: targetColumns) }
        let totalRows = max(1, normalizedRows.count)
        let visibleStart = resizeHiddenRowsAbove.count
        let clampedAnchor = min(max(0, anchorRow ?? rows - 1), max(0, rows - 1))
        let anchorAbsoluteRow = min(totalRows - 1, visibleStart + clampedAnchor)
        let preferredAnchorRow = min(clampedAnchor, targetRows - 1)
        let maxStart = max(0, totalRows - targetRows)
        let start = max(0, min(anchorAbsoluteRow - preferredAnchorRow, maxStart))
        let end = min(totalRows, start + targetRows)
        var resized = Array(repeating: TerminalScreen.blankRow(columns: targetColumns), count: targetRows)
        if !normalizedRows.isEmpty {
            for targetRow in 0..<(end - start) {
                resized[targetRow] = normalizedRows[start + targetRow]
            }
        }
        resizeHiddenRowsAbove = start > 0 ? Array(normalizedRows[..<start]) : []
        resizeHiddenRowsBelow = end < normalizedRows.count ? Array(normalizedRows[end...]) : []
        rows = targetRows
        columns = targetColumns
        cells = resized
        return min(targetRows - 1, max(0, anchorAbsoluteRow - start))
    }

    public mutating func clear(style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        cells = Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: rows)
    }

    public mutating func clear(row: Int, style: TerminalTextStyle = .default) {
        guard cells.indices.contains(row) else { return }
        cells[row] = TerminalScreen.blankRow(columns: columns, style: style)
    }

    public mutating func clear(row: Int, from start: Int, through end: Int, style: TerminalTextStyle = .default) {
        guard cells.indices.contains(row) else { return }
        guard start <= end, start < columns, end >= 0 else { return }
        let lower = max(0, min(start, columns - 1))
        let upper = max(0, min(end, columns - 1))
        guard lower <= upper else { return }
        for column in lower...upper {
            cells[row][column] = TerminalScreenCell(style: style)
        }
    }

    public mutating func set(character: Character, row: Int, column: Int, width: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        clearWideCellIfNeeded(row: row, column: column, style: style)
        cells[row][column] = TerminalScreenCell(character: character, isContinuation: false, style: style)
        if width == 2 && column + 1 < columns {
            cells[row][column + 1] = TerminalScreenCell(character: " ", isContinuation: true, style: style)
        }
        if column > 0 && cells[row][column - 1].isContinuation {
            cells[row][column - 1] = TerminalScreenCell(style: style)
        }
        if width == 1 && column + 1 < columns && cells[row][column + 1].isContinuation {
            cells[row][column + 1] = TerminalScreenCell(style: style)
        }
    }

    public mutating func appendCombining(character: Character, row: Int, before column: Int) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column > 0 else { return }
        var leadColumn = min(column - 1, columns - 1)
        while leadColumn > 0 && cells[row][leadColumn].isContinuation {
            leadColumn -= 1
        }
        guard cells[row][leadColumn].character != " " else { return }
        let merged = String(cells[row][leadColumn].character) + String(character)
        if merged.count == 1, let composed = merged.first {
            cells[row][leadColumn].character = composed
        }
    }

    @discardableResult
    public mutating func repeatPrecedingGraphicCharacter(row: Int, column: Int, count: Int) -> Int {
        discardResizeHiddenRows()
        guard cells.indices.contains(row),
              column > 0,
              column < columns,
              count > 0
        else {
            return 0
        }

        let source = cells[row][column - 1]
        guard !source.isContinuation,
              source.character.terminalColumnWidth == 1
        else {
            return 0
        }

        let writableCount = min(count, columns - column)
        guard writableCount > 0 else { return 0 }

        for offset in 0..<writableCount {
            set(
                character: source.character,
                row: row,
                column: column + offset,
                width: 1,
                style: source.style
            )
        }
        return writableCount
    }

    private mutating func clearWideCellIfNeeded(row: Int, column: Int, style: TerminalTextStyle) {
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        guard cells[row][column].isContinuation else { return }
        var leadColumn = column
        while leadColumn > 0 && cells[row][leadColumn].isContinuation {
            leadColumn -= 1
        }
        cells[row][leadColumn] = TerminalScreenCell(style: style)
        var nextColumn = leadColumn + 1
        while nextColumn < columns && cells[row][nextColumn].isContinuation {
            cells[row][nextColumn] = TerminalScreenCell(style: style)
            nextColumn += 1
        }
    }

    @discardableResult
    public mutating func scrollUp(count: Int = 1) -> [[TerminalScreenCell]] {
        scrollUpRegion(top: 0, bottom: rows - 1, count: count)
    }

    public mutating func scrollDown(count: Int = 1) {
        _ = scrollDownRegion(top: 0, bottom: rows - 1, count: count)
    }

    @discardableResult
    public mutating func scrollUpRegion(top: Int, bottom: Int, count: Int = 1, style: TerminalTextStyle = .default) -> [[TerminalScreenCell]] {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: top, bottom: bottom) else { return [] }
        let amount = min(max(1, count), region.count)
        let removed = Array(cells[region.lowerBound..<(region.lowerBound + amount)])
        cells.removeSubrange(region.lowerBound..<(region.lowerBound + amount))
        cells.insert(
            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),
            at: region.upperBound - amount + 1
        )
        return removed
    }

    @discardableResult
    public mutating func scrollDownRegion(top: Int, bottom: Int, count: Int = 1, style: TerminalTextStyle = .default) -> [[TerminalScreenCell]] {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: top, bottom: bottom) else { return [] }
        let amount = min(max(1, count), region.count)
        let lower = region.upperBound - amount + 1
        let removed = Array(cells[lower...region.upperBound])
        cells.removeSubrange(lower...region.upperBound)
        cells.insert(
            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),
            at: region.lowerBound
        )
        return removed
    }

    public mutating func insertLines(at row: Int, count: Int, style: TerminalTextStyle = .default) {
        insertLines(at: row, bottom: rows - 1, count: count, style: style)
    }

    public mutating func insertLines(at row: Int, bottom: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: row, bottom: bottom) else { return }
        let amount = min(max(1, count), region.count)
        cells.removeSubrange((region.upperBound - amount + 1)...region.upperBound)
        cells.insert(contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount), at: region.lowerBound)
    }

    public mutating func deleteLines(at row: Int, count: Int, style: TerminalTextStyle = .default) {
        deleteLines(at: row, bottom: rows - 1, count: count, style: style)
    }

    public mutating func deleteLines(at row: Int, bottom: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard let region = normalizedRegion(top: row, bottom: bottom) else { return }
        let amount = min(max(1, count), region.count)
        cells.removeSubrange(region.lowerBound..<(region.lowerBound + amount))
        cells.insert(
            contentsOf: Array(repeating: TerminalScreen.blankRow(columns: columns, style: style), count: amount),
            at: region.upperBound - amount + 1
        )
    }

    public mutating func insertCharacters(row: Int, column: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        let amount = min(max(1, count), columns - column)
        var line = cells[row]
        line.removeSubrange((columns - amount)..<columns)
        line.insert(contentsOf: Array(repeating: TerminalScreenCell(style: style), count: amount), at: column)
        cells[row] = line
    }

    public mutating func deleteCharacters(row: Int, column: Int, count: Int, style: TerminalTextStyle = .default) {
        discardResizeHiddenRows()
        guard cells.indices.contains(row), column >= 0, column < columns else { return }
        let amount = min(max(1, count), columns - column)
        var line = cells[row]
        line.removeSubrange(column..<(column + amount))
        line.append(contentsOf: Array(repeating: TerminalScreenCell(style: style), count: amount))
        cells[row] = line
    }

    public mutating func discardResizeHiddenRows() {
        resizeHiddenRowsAbove.removeAll(keepingCapacity: true)
        resizeHiddenRowsBelow.removeAll(keepingCapacity: true)
    }

    public mutating func remapStyle(from previousStyle: TerminalTextStyle, to nextStyle: TerminalTextStyle) {
        guard previousStyle != nextStyle else { return }
        remapStyle(in: &cells, from: previousStyle, to: nextStyle)
        remapStyle(in: &resizeHiddenRowsAbove, from: previousStyle, to: nextStyle)
        remapStyle(in: &resizeHiddenRowsBelow, from: previousStyle, to: nextStyle)
    }

    public mutating func remapColors(_ colorMap: TerminalStyleColorMap) {
        remapColors(in: &cells, colorMap: colorMap)
        remapColors(in: &resizeHiddenRowsAbove, colorMap: colorMap)
        remapColors(in: &resizeHiddenRowsBelow, colorMap: colorMap)
    }

    private func remapStyle(
        in rows: inout [[TerminalScreenCell]],
        from previousStyle: TerminalTextStyle,
        to nextStyle: TerminalTextStyle
    ) {
        for rowIndex in rows.indices {
            for columnIndex in rows[rowIndex].indices where rows[rowIndex][columnIndex].style == previousStyle {
                rows[rowIndex][columnIndex].style = nextStyle
            }
        }
    }

    private func remapColors(in rows: inout [[TerminalScreenCell]], colorMap: TerminalStyleColorMap) {
        for rowIndex in rows.indices {
            for columnIndex in rows[rowIndex].indices {
                rows[rowIndex][columnIndex].style = rows[rowIndex][columnIndex].style.remappingColors(colorMap)
            }
        }
    }

    private func normalizedRegion(top: Int, bottom: Int) -> ClosedRange<Int>? {
        guard rows > 0 else { return nil }
        let lower = max(0, min(top, rows - 1))
        let upper = max(0, min(bottom, rows - 1))
        guard lower <= upper else { return nil }
        return lower...upper
    }

    public static func blankRow(columns: Int, style: TerminalTextStyle = .default) -> [TerminalScreenCell] {
        Array(repeating: TerminalScreenCell(style: style), count: columns)
    }

    private static func resize(row: [TerminalScreenCell], columns: Int) -> [TerminalScreenCell] {
        if row.count == columns {
            return row
        }
        if row.count > columns {
            return Array(row.prefix(columns))
        }
        return row + Array(repeating: TerminalScreenCell(), count: columns - row.count)
    }
}

public struct TerminalScreenCell: Equatable, Sendable {
    public var character: Character
    public var isContinuation: Bool
    public var style: TerminalTextStyle

    public init(character: Character = " ", isContinuation: Bool = false, style: TerminalTextStyle = .default) {
        self.character = character
        self.isContinuation = isContinuation
        self.style = style
    }
}

public struct CsiParameters: Sendable {
    public let isPrivate: Bool
    public let prefix: Character?
    public let values: [Int]

    public init(_ raw: String) {
        let privatePrefixes = CharacterSet(charactersIn: "<=>?")
        let trimmed = raw.trimmingCharacters(in: privatePrefixes)
        prefix = raw.first.flatMap { character in
            guard let scalar = character.unicodeScalars.first,
                  privatePrefixes.contains(scalar)
            else {
                return nil
            }
            return character
        }
        isPrivate = prefix != nil
        values = trimmed
            .split(whereSeparator: { $0 == ";" || $0 == ":" })
            .map { part in
                Int(part.filter(\.isNumber)) ?? 0
            }
    }

    public func value(at index: Int, default defaultValue: Int) -> Int {
        guard values.indices.contains(index), values[index] > 0 else { return defaultValue }
        return values[index]
    }
}

public enum TerminalDeviceAttributes {
    public static func response(for params: CsiParameters) -> String? {
        switch params.prefix {
        case nil:
            guard params.values.isEmpty || params.value(at: 0, default: 0) == 0 else {
                return nil
            }
            return "\u{1b}[?1;2c"
        case ">":
            guard params.values.isEmpty || params.value(at: 0, default: 0) == 0 else {
                return nil
            }
            return "\u{1b}[>0;0;0c"
        default:
            return nil
        }
    }
}
