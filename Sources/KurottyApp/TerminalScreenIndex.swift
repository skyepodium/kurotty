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
    private(set) var marked: Set<Int> = []

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

        overlayMarkedText(frame: frame)
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
            isMarked: marked.contains(index),
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
        /// Part of an input method's composition rather than of the screen
        /// buffer. Carried so a renderer can mark it without being told where
        /// the composition is.
        var isMarked: Bool
        var shapes: [TerminalCellGeometry.Shape]
    }

    // MARK: - Marked text

    /// Lays the input method's preedit over the row the composition sits on.
    ///
    /// The frame carries the composition rather than the screen buffer, because
    /// `setMarkedText` is preedit state and must never be written to the
    /// terminal as committed text. Drawing it is therefore the renderer's job,
    /// and a document renderer that skipped it left a user composing Hangul
    /// with nothing on screen until the syllable committed.
    ///
    /// The cells underneath are dropped rather than drawn behind, which is what
    /// `TerminalMetalView` does with the same range: the composition replaces
    /// what is on the line for as long as it lasts.
    ///
    /// Here rather than in a renderer because it is a fact about the screen —
    /// which cells show what — and both backends need the same answer.
    private mutating func overlayMarkedText(frame: TerminalFrame) {
        guard let range = frame.markedTextRenderRange, frame.cursorRow >= 0 else {
            return
        }

        let row = frame.cursorRow

        // A wide cell whose head sits just before the composition would
        // otherwise be stepped over the first covered column and shift the
        // preedit one cell to the right, so it goes as well.
        if range.startColumn > 0 {
            let head = key(row, range.startColumn - 1)
            if (columnSpans[head] ?? TerminalCellColumns.single) > TerminalCellColumns.single {
                erase(head)
            }
        }
        for column in range.cellRange {
            erase(key(row, column))
        }

        var column = range.startColumn
        var characterOffset = 0
        var utf16Offset = 0

        for character in frame.markedText {
            defer {
                characterOffset += 1
                utf16Offset += String(character).utf16.count
            }
            guard characterOffset >= range.sourceCharacterOffset else {
                continue
            }

            // The same width function the range was laid out with. The screen's
            // own cells carry their width from the Zig grid, but a preedit
            // character was never in that grid — asking a second width function
            // here would let the two disagree and run the composition off the
            // end of its own range.
            let width = max(character.terminalColumnWidth, TerminalCellColumns.single)
            guard column + width <= range.endColumn else {
                break
            }

            let index = key(row, column)
            characters[index] = character
            columnSpans[index] = width
            foregrounds[index] = Self.markedForeground(
                utf16Offset: utf16Offset,
                utf16Length: String(character).utf16.count,
                frame: frame
            )
            marked.insert(index)
            column += width
        }
    }

    /// The colour one preedit character is drawn in.
    ///
    /// The input method selects a sub-range of its own composition — in Hangul,
    /// the syllable currently being built — and that sub-range is what tells the
    /// user where the next keystroke lands. `TerminalMetalView` distinguishes it
    /// by drawing it in the selection foreground while the rest of the
    /// composition keeps the screen's; this matches that rather than inventing a
    /// second convention.
    static func markedForeground(
        utf16Offset: Int,
        utf16Length: Int,
        frame: TerminalFrame
    ) -> SIMD4<Float> {
        let selection = frame.markedTextSelectedRange

        guard selection.location != TerminalTextSelectionRange.notFound,
              selection.length > 0,
              utf16Offset < selection.location + selection.length,
              selection.location < utf16Offset + utf16Length
        else {
            return frame.defaultForeground
        }

        return TerminalSelectionStyle.foregroundColor
    }

    /// Drops whatever was drawn in a cell, leaving its background alone.
    private mutating func erase(_ index: Int) {
        characters.removeValue(forKey: index)
        columnSpans.removeValue(forKey: index)
        foregrounds.removeValue(forKey: index)
        shapes.removeValue(forKey: index)
        underlined.remove(index)
        struckThrough.remove(index)
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
