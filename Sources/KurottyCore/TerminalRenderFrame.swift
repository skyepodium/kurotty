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

    public var damageMetadata: TerminalFrameDamageMetadata {
        TerminalFrameDamageMetadata(
            isFullDamage: isFullDamage,
            dirtyRows: dirtyRows,
            dirtyRects: dirtyRects
        )
    }

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

    public func stablePixelBounds(
        scale: Double,
        clippingMargin: Double = 0,
        clipTo displaySize: TerminalFrameSize? = nil
    ) -> TerminalFramePixelRect? {
        guard isStableDamageRect,
              scale.isFinite,
              scale > 0,
              clippingMargin.isFinite,
              clippingMargin >= 0
        else {
            return nil
        }

        var minX = ((x - clippingMargin) * scale).rounded(.down)
        var minY = ((y - clippingMargin) * scale).rounded(.down)
        var maxX = ((x + width + clippingMargin) * scale).rounded(.up)
        var maxY = ((y + height + clippingMargin) * scale).rounded(.up)

        if let displaySize {
            guard displaySize.width.isFinite,
                  displaySize.height.isFinite,
                  displaySize.width > 0,
                  displaySize.height > 0
            else {
                return nil
            }
            minX = max(0, minX)
            minY = max(0, minY)
            maxX = min((displaySize.width * scale).rounded(.up), maxX)
            maxY = min((displaySize.height * scale).rounded(.up), maxY)
        }

        let pixelWidth = maxX - minX
        let pixelHeight = maxY - minY
        guard pixelWidth > 0,
              pixelHeight > 0,
              minX >= Double(Int.min),
              minY >= Double(Int.min),
              minX <= Double(Int.max),
              minY <= Double(Int.max),
              pixelWidth <= Double(Int.max),
              pixelHeight <= Double(Int.max)
        else {
            return nil
        }

        return TerminalFramePixelRect(
            x: Int(minX),
            y: Int(minY),
            width: Int(pixelWidth),
            height: Int(pixelHeight)
        )
    }

    public var isStableDamageRect: Bool {
        x.isFinite &&
            y.isFinite &&
            width.isFinite &&
            height.isFinite &&
            width > 0 &&
            height > 0
    }
}

public struct TerminalFramePixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TerminalFrameDamageMetadata: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case none
        case fullRedraw
        case rowDamage
        case rectDamage
    }

    public let kind: Kind
    public let dirtyRowCount: Int
    public let dirtyRectCount: Int
    public let dirtyRects: [TerminalFrameRect]

    public init(
        isFullDamage: Bool,
        dirtyRows: [Int],
        dirtyRects: [TerminalFrameRect]
    ) {
        self.kind = Self.kind(
            isFullDamage: isFullDamage,
            dirtyRows: dirtyRows,
            dirtyRects: dirtyRects
        )
        self.dirtyRowCount = dirtyRows.count
        self.dirtyRectCount = dirtyRects.count
        self.dirtyRects = dirtyRects
    }

    public func canResolveStablePixelBounds(
        scale: Double,
        clippingMargin: Double = 0,
        clipTo displaySize: TerminalFrameSize? = nil
    ) -> Bool {
        !dirtyRects.isEmpty &&
            dirtyRects.allSatisfy {
                $0.stablePixelBounds(
                    scale: scale,
                    clippingMargin: clippingMargin,
                    clipTo: displaySize
                ) != nil
            }
    }

    public func stablePixelBounds(
        scale: Double,
        clippingMargin: Double = 0,
        clipTo displaySize: TerminalFrameSize? = nil
    ) -> [TerminalFramePixelRect]? {
        guard !dirtyRects.isEmpty else { return nil }
        var pixelRects: [TerminalFramePixelRect] = []
        pixelRects.reserveCapacity(dirtyRects.count)
        for rect in dirtyRects {
            guard let pixelRect = rect.stablePixelBounds(
                scale: scale,
                clippingMargin: clippingMargin,
                clipTo: displaySize
            ) else {
                return nil
            }
            pixelRects.append(pixelRect)
        }
        return pixelRects
    }

    private static func kind(
        isFullDamage: Bool,
        dirtyRows: [Int],
        dirtyRects: [TerminalFrameRect]
    ) -> Kind {
        if isFullDamage {
            return .fullRedraw
        }
        if !dirtyRows.isEmpty {
            return .rowDamage
        }
        if !dirtyRects.isEmpty {
            return .rectDamage
        }
        return .none
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
