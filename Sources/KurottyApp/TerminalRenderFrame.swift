struct TerminalFrame {
    let cells: [TerminalCell]
    let backgrounds: [TerminalBackground]
    let decorations: [TerminalDecoration]
    let defaultForeground: SIMD4<Float>
    let defaultBackground: SIMD4<Float>
    let dirtyRows: [Int]
    let dirtyRects: [TerminalFrameRect]
    let isFullDamage: Bool
    let cursorColumn: Int
    let cursorRow: Int
    let cursorBlinkOn: Bool
    let markedTextColumn: Int
    let markedText: String
    let markedTextSelectedRange: TerminalTextSelectionRange
    let columns: Int
    let visibleRows: Int
    let cellSize: TerminalFrameSize
    let padding: TerminalFramePoint
}

struct TerminalCell {
    let character: Character
    let column: Int
    let row: Int
    let foreground: SIMD4<Float>
    let background: SIMD4<Float>
}

struct TerminalBackground {
    let column: Int
    let row: Int
    let color: SIMD4<Float>
}

struct TerminalDecoration {
    let column: Int
    let row: Int
    let width: Int
    let kind: Kind
    let color: SIMD4<Float>

    enum Kind {
        case underline
        case strikethrough
        case boxDrawing(left: Bool, right: Bool, up: Bool, down: Bool)
    }
}

struct TerminalFrameSize: Equatable {
    static let zero = TerminalFrameSize(width: 0, height: 0)

    let width: Double
    let height: Double
}

struct TerminalFramePoint: Equatable {
    static let zero = TerminalFramePoint(x: 0, y: 0)

    let x: Double
    let y: Double
}

struct TerminalFrameRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct TerminalTextSelectionRange: Equatable {
    static let notFound = -1
    static let none = TerminalTextSelectionRange(location: notFound, length: 0)

    let location: Int
    let length: Int
}
