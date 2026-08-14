import Foundation
import KurottyCore

/// A frame's three flat arrays, addressable by position.
///
/// `TerminalFrame` carries cells, backgrounds and decorations in whatever order
/// the surface built them, which is the right shape for handing across a
/// boundary and the wrong shape for drawing: a renderer walks the screen by row
/// and column, and searching three arrays per cell is quadratic on exactly the
/// frame a full repaint produces.
///
/// Free of AppKit and of any renderer, so a second backend — a canvas path, a
/// future Linux frontend — indexes a frame the same way rather than inventing a
/// second answer. That is not hypothetical here: cell width was already being
/// derived three different ways before it was carried on the cell itself.
struct TerminalScreenIndex {
    let columns: Int
    let rows: Int
    private(set) var characters: [Int: Character] = [:]
    private(set) var columnSpans: [Int: Int] = [:]
    private(set) var foregrounds: [Int: SIMD4<Float>] = [:]
    private(set) var backgrounds: [Int: SIMD4<Float>] = [:]
    private(set) var underlined: Set<Int> = []
    private(set) var struckThrough: Set<Int> = []
    private(set) var shapes: [Int: [TerminalCellGeometry.Shape]] = [:]

    let defaultForeground: SIMD4<Float>
    let defaultBackground: SIMD4<Float>

    init(frame: TerminalFrame) {
        columns = max(frame.columns, 1)
        rows = max(frame.visibleRows, 0)
        defaultForeground = frame.defaultForeground
        defaultBackground = frame.defaultBackground

        for background in frame.backgrounds {
            backgrounds[key(background.row, background.column)] = background.color
        }

        for cell in frame.cells {
            let index = key(cell.row, cell.column)
            characters[index] = cell.character
            columnSpans[index] = cell.columns
            foregrounds[index] = cell.foreground
            backgrounds[index] = cell.background
        }

        for decoration in frame.decorations {
            add(decoration)
        }
    }

    func key(_ row: Int, _ column: Int) -> Int {
        row * columns + column
    }

    /// What a cell looks like, with the frame's defaults already applied so no
    /// caller repeats the fallback.
    func attributes(at index: Int) -> Attributes {
        Attributes(
            character: characters[index] ?? " ",
            columns: max(columnSpans[index] ?? TerminalCellColumns.single, TerminalCellColumns.single),
            foreground: foregrounds[index] ?? defaultForeground,
            background: backgrounds[index] ?? defaultBackground,
            isUnderlined: underlined.contains(index),
            isStruckThrough: struckThrough.contains(index),
            shapes: shapes[index] ?? []
        )
    }

    struct Attributes: Equatable {
        var character: Character
        var columns: Int
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var isUnderlined: Bool
        var isStruckThrough: Bool
        var shapes: [TerminalCellGeometry.Shape]
    }

    // MARK: - Decorations

    /// One decoration, spread across the cells it covers.
    ///
    /// Split out of the initializer so the loop above stays a loop and the
    /// per-kind work is a flat switch rather than a switch nested two deep
    /// inside two `for`s.
    private mutating func add(_ decoration: TerminalDecoration) {
        let span = max(decoration.width, 1)

        for offset in 0..<span {
            let index = key(decoration.row, decoration.column + offset)

            switch decoration.kind {
            case .underline:
                underlined.insert(index)
            case .strikethrough:
                struckThrough.insert(index)
            case let .blockElement(x, y, width, height):
                shapes[index, default: []].append(
                    TerminalCellGeometry.block(
                        x: x, y: y, width: width, height: height,
                        color: decoration.color
                    )
                )
            case let .boxDrawing(left, right, up, down):
                shapes[index, default: []].append(
                    contentsOf: TerminalCellGeometry.box(
                        left: left, right: right, up: up, down: down,
                        color: decoration.color
                    )
                )
            }
        }
    }
}
