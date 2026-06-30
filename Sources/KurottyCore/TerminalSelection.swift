import Foundation

public struct TerminalSelectionPosition: Hashable, Comparable, Sendable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalSelectionPosition, rhs: TerminalSelectionPosition) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }
}

public struct TerminalSelectionRangeModel: Equatable, Sendable {
    public let start: TerminalSelectionPosition
    public let end: TerminalSelectionPosition

    public init(start: TerminalSelectionPosition, end: TerminalSelectionPosition) {
        self.start = start
        self.end = end
    }

    public static func normalized(anchor: TerminalSelectionPosition?, focus: TerminalSelectionPosition?) -> TerminalSelectionRangeModel? {
        guard let anchor, let focus else { return nil }
        if anchor < focus {
            return TerminalSelectionRangeModel(start: anchor, end: focus)
        }
        return TerminalSelectionRangeModel(start: focus, end: anchor)
    }
}

public struct TerminalSelectionGestureState: Sendable {
    private var wordSelectionIsActive = false

    public init() {}

    public mutating func beginCharacterSelection() {
        wordSelectionIsActive = false
    }

    public mutating func selectWord() {
        wordSelectionIsActive = true
    }

    public func shouldUpdateFocusOnPointerDrag() -> Bool {
        !wordSelectionIsActive
    }

    public mutating func shouldUpdateFocusOnPointerUp() -> Bool {
        guard wordSelectionIsActive else {
            return true
        }
        return false
    }
}

public enum TerminalWordSelection: Sendable {
    public struct Cell: Equatable, Sendable {
        public let character: Character
        public let isContinuation: Bool

        public init(character: Character, isContinuation: Bool) {
            self.character = character
            self.isContinuation = isContinuation
        }
    }

    public struct Bounds: Equatable, Sendable {
        public let startColumn: Int
        public let endColumn: Int

        public init(startColumn: Int, endColumn: Int) {
            self.startColumn = startColumn
            self.endColumn = endColumn
        }

        public func highlightEndColumn(in row: [Cell]) -> Int {
            guard row.indices.contains(endColumn) else { return endColumn }
            let cell = row[endColumn]
            guard !cell.isContinuation else { return endColumn }
            return min(row.count - 1, endColumn + max(1, cell.character.terminalColumnWidth) - 1)
        }
    }

    private static let excludedCharacters = CharacterSet(charactersIn: "()[]{}<>\"'`")

    public static func bounds(in row: [Cell], clickedColumn: Int) -> Bounds? {
        guard row.indices.contains(clickedColumn) else { return nil }
        let wordColumn = normalizedWordColumn(in: row, clickedColumn: clickedColumn)
        guard row.indices.contains(wordColumn), isSelectableWordCell(in: row, column: wordColumn) else {
            return nil
        }

        var startColumn = wordColumn
        var endColumn = wordColumn
        while startColumn > 0, isSelectableWordCell(in: row, column: startColumn - 1) {
            startColumn -= 1
        }
        while endColumn + 1 < row.count, isSelectableWordCell(in: row, column: endColumn + 1) {
            endColumn += 1
        }
        return Bounds(startColumn: startColumn, endColumn: endColumn)
    }

    private static func normalizedWordColumn(in row: [Cell], clickedColumn: Int) -> Int {
        if isBlank(row[clickedColumn]) {
            if clickedColumn > 0, row[clickedColumn - 1].isContinuation {
                return normalizedWordColumn(in: row, clickedColumn: clickedColumn - 1)
            }
            if clickedColumn + 1 < row.count, isWideLeadCell(row[clickedColumn + 1]) {
                return clickedColumn + 1
            }
            return clickedColumn
        }
        guard row[clickedColumn].isContinuation else { return clickedColumn }
        var column = clickedColumn
        while column > 0, row[column].isContinuation {
            column -= 1
        }
        return column
    }

    private static func isSelectableWordCell(in row: [Cell], column: Int) -> Bool {
        guard row.indices.contains(column) else { return false }
        let cell = row[column]
        if cell.isContinuation {
            return true
        }
        if isBlank(cell) {
            return isCJKWordSpacer(in: row, column: column)
        }
        let character = String(cell.character)
        guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return character.rangeOfCharacter(from: excludedCharacters) == nil
    }

    public static func isSyntheticCJKSpacer(in row: [Cell], column: Int) -> Bool {
        isCJKWordSpacer(in: row, column: column)
    }

    private static func isBlank(_ cell: Cell) -> Bool {
        !cell.isContinuation && String(cell.character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isWideLeadCell(_ cell: Cell) -> Bool {
        !cell.isContinuation && cell.character.terminalColumnWidth > 1
    }

    private static func isCJKWordSpacer(in row: [Cell], column: Int) -> Bool {
        guard isBlank(row[column]) else { return false }
        guard blankRunLength(in: row, containing: column) == 1,
              let left = nearestNonBlankCell(in: row, from: column, step: -1),
              let right = nearestNonBlankCell(in: row, from: column, step: 1)
        else {
            return false
        }
        return isCJKWordCell(left) && (isCJKWordCell(right) || isWordPunctuationCell(right))
            || isCJKWordCell(right) && isWordPunctuationCell(left)
    }

    private static func blankRunLength(in row: [Cell], containing column: Int) -> Int {
        guard row.indices.contains(column), isBlank(row[column]) else { return 0 }
        var startColumn = column
        while startColumn > 0, isBlank(row[startColumn - 1]) {
            startColumn -= 1
        }
        var endColumn = column
        while endColumn + 1 < row.count, isBlank(row[endColumn + 1]) {
            endColumn += 1
        }
        return endColumn - startColumn + 1
    }

    private static func nearestNonBlankCell(in row: [Cell], from column: Int, step: Int) -> Cell? {
        var nextColumn = column + step
        while row.indices.contains(nextColumn) {
            let cell = row[nextColumn]
            if !isBlank(cell) {
                return cell.isContinuation && step < 0 && nextColumn > 0 ? row[nextColumn - 1] : cell
            }
            nextColumn += step
        }
        return nil
    }

    private static func isCJKWordCell(_ cell: Cell) -> Bool {
        guard !cell.isContinuation else { return true }
        guard cell.character.terminalColumnWidth > 1 else { return false }
        return String(cell.character).rangeOfCharacter(from: excludedCharacters) == nil
    }

    private static func isWordPunctuationCell(_ cell: Cell) -> Bool {
        guard !cell.isContinuation else { return false }
        guard cell.character.terminalColumnWidth == 1 else { return false }
        let character = String(cell.character)
        guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard character.rangeOfCharacter(from: .alphanumerics) == nil else {
            return false
        }
        return character.rangeOfCharacter(from: excludedCharacters) == nil
    }
}

public enum TerminalSelectionText {
    public static func line<S: Sequence>(from cells: S) -> String where S.Element == TerminalWordSelection.Cell {
        let row = Array(cells)
        let characters = row.indices.lazy.compactMap { column -> Character? in
            let cell = row[column]
            if cell.isContinuation || TerminalWordSelection.isSyntheticCJKSpacer(in: row, column: column) {
                return nil
            }
            return cell.character
        }
        return String(characters)
            .trimmingCharacters(in: .whitespaces)
    }
}

public enum TerminalSelectionStyle {
    public static let backgroundColor = SIMD4<Float>(0.22, 0.48, 0.82, 1)
    public static let foregroundColor = SIMD4<Float>(1, 1, 1, 1)
}
