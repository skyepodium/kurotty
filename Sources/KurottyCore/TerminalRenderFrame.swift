public struct TerminalFrame: Sendable {
    public let cells: [TerminalCell]
    public let backgrounds: [TerminalBackground]
    public let decorations: [TerminalDecoration]
    public let defaultForeground: SIMD4<Float>
    public let defaultBackground: SIMD4<Float>
    public let dirtyRows: [Int]
    public let dirtyRects: [TerminalFrameRect]
    public let isFullDamage: Bool
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorBlinkOn: Bool
    public let markedTextColumn: Int
    public let markedText: String
    public let markedTextSelectedRange: TerminalTextSelectionRange
    public let columns: Int
    public let visibleRows: Int
    public let cellSize: TerminalFrameSize
    public let padding: TerminalFramePoint

    public init(
        cells: [TerminalCell],
        backgrounds: [TerminalBackground],
        decorations: [TerminalDecoration],
        defaultForeground: SIMD4<Float>,
        defaultBackground: SIMD4<Float>,
        dirtyRows: [Int],
        dirtyRects: [TerminalFrameRect],
        isFullDamage: Bool,
        cursorColumn: Int,
        cursorRow: Int,
        cursorBlinkOn: Bool,
        markedTextColumn: Int,
        markedText: String,
        markedTextSelectedRange: TerminalTextSelectionRange,
        columns: Int,
        visibleRows: Int,
        cellSize: TerminalFrameSize,
        padding: TerminalFramePoint
    ) {
        self.cells = cells
        self.backgrounds = backgrounds
        self.decorations = decorations
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.dirtyRows = dirtyRows
        self.dirtyRects = dirtyRects
        self.isFullDamage = isFullDamage
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorBlinkOn = cursorBlinkOn
        self.markedTextColumn = markedTextColumn
        self.markedText = markedText
        self.markedTextSelectedRange = markedTextSelectedRange
        self.columns = columns
        self.visibleRows = visibleRows
        self.cellSize = cellSize
        self.padding = padding
    }
}

public struct TerminalCell: Sendable {
    public let character: Character
    public let column: Int
    public let row: Int
    public let foreground: SIMD4<Float>
    public let background: SIMD4<Float>

    public init(
        character: Character,
        column: Int,
        row: Int,
        foreground: SIMD4<Float>,
        background: SIMD4<Float>
    ) {
        self.character = character
        self.column = column
        self.row = row
        self.foreground = foreground
        self.background = background
    }
}

public struct TerminalBackground: Sendable {
    public let column: Int
    public let row: Int
    public let color: SIMD4<Float>

    public init(column: Int, row: Int, color: SIMD4<Float>) {
        self.column = column
        self.row = row
        self.color = color
    }
}

public struct TerminalDecoration: Sendable {
    public let column: Int
    public let row: Int
    public let width: Int
    public let kind: Kind
    public let color: SIMD4<Float>

    public init(column: Int, row: Int, width: Int, kind: Kind, color: SIMD4<Float>) {
        self.column = column
        self.row = row
        self.width = width
        self.kind = kind
        self.color = color
    }

    public enum Kind: Sendable {
        case underline
        case strikethrough
        case boxDrawing(left: Bool, right: Bool, up: Bool, down: Bool)
        case blockElement(x: Double, y: Double, width: Double, height: Double)
    }
}

public struct TerminalFrameSize: Equatable, Sendable {
    public static let zero = TerminalFrameSize(width: 0, height: 0)

    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct TerminalFramePoint: Equatable, Sendable {
    public static let zero = TerminalFramePoint(x: 0, y: 0)

    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct TerminalFrameRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TerminalTextSelectionRange: Equatable, Sendable {
    public static let notFound = -1
    public static let none = TerminalTextSelectionRange(location: notFound, length: 0)

    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}
