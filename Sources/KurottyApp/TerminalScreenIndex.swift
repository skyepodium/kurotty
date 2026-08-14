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
/// **Built once per frame, not once per row.** Answering about a single row used
/// to rebuild the whole index, so patching a screen's worth of damage rebuilt it
/// once for every row: 97.5ms to patch a 55x200 screen against 5.2ms to build
/// that screen in one pass. Callers hold one of these for the frame.
///
/// **Flat arrays rather than dictionaries.** The index is already an integer in a
/// known range, so hashing it buys nothing, and a full screen meant tens of
/// thousands of dictionary insertions per frame plus a hash on every lookup
/// during coalescing.
///
/// Free of AppKit and of any renderer, so a second backend — a canvas path, a
/// future Linux frontend — indexes a frame the same way rather than inventing a
/// second answer. That is not hypothetical here: cell width was already being
/// derived three different ways before it was carried on the cell itself.
struct TerminalScreenIndex {
    let columns: Int
    let rows: Int

    private var characters: [Character]
    private var columnSpans: [UInt8]
    private var foregrounds: [SIMD4<Float>]
    private var backgrounds: [SIMD4<Float>]
    private var underlined: [Bool]
    private var struckThrough: [Bool]
    private var isMarked: [Bool]
    /// Sparse on purpose: geometry cells are rare even in a box-drawing TUI, and
    /// an array of empty arrays would cost more than it saves.
    private var shapes: [Int: [TerminalCellGeometry.Shape]]

    private enum Defaults {
        static let character: Character = " "
        static let columnSPAN = UInt8(TerminalCellColumns.single)
    }

    init(frame: TerminalFrame) {
        columns = max(frame.columns, 1)
        rows = max(frame.visibleRows, 0)

        let cellCOUNT = columns * rows
        characters = Array(repeating: Defaults.character, count: cellCOUNT)
        columnSpans = Array(repeating: Defaults.columnSPAN, count: cellCOUNT)
        foregrounds = Array(repeating: frame.defaultForeground, count: cellCOUNT)
        backgrounds = Array(repeating: frame.defaultBackground, count: cellCOUNT)
        underlined = Array(repeating: false, count: cellCOUNT)
        struckThrough = Array(repeating: false, count: cellCOUNT)
        isMarked = Array(repeating: false, count: cellCOUNT)
        shapes = [:]

        for background in frame.backgrounds {
            guard let index = index(background.row, background.column) else {
                continue
            }
            backgrounds[index] = background.color
        }

        for cell in frame.cells {
            guard let index = index(cell.row, cell.column) else {
                continue
            }
            characters[index] = cell.character
            columnSpans[index] = UInt8(clamping: cell.columns)
            foregrounds[index] = cell.foreground
            backgrounds[index] = cell.background
        }

        for decoration in frame.decorations {
            add(decoration)
        }

        overlayMarkedText(frame: frame)
    }

    /// A position's index, or nil when it is off the screen.
    ///
    /// Bounds-checked here rather than trusted, because the arrays are sized to
    /// the screen and a frame's cells arrive from a different process: a stale
    /// column from a resize that crossed the boundary mid-flight would otherwise
    /// be a crash rather than a dropped cell.
    private func index(_ row: Int, _ column: Int) -> Int? {
        guard row >= 0, row < rows, column >= 0, column < columns else {
            return nil
        }
        return row * columns + column
    }

    /// What a cell looks like, with the frame's defaults already applied so no
    /// caller repeats the fallback.
    func attributes(row: Int, column: Int) -> Attributes {
        guard let index = index(row, column) else {
            return Attributes(
                character: Defaults.character,
                columns: TerminalCellColumns.single,
                foreground: .zero,
                background: .zero,
                isUnderlined: false,
                isStruckThrough: false,
                isMarked: false,
                shapes: []
            )
        }

        return Attributes(
            character: characters[index],
            columns: max(Int(columnSpans[index]), TerminalCellColumns.single),
            foreground: foregrounds[index],
            background: backgrounds[index],
            isUnderlined: underlined[index],
            isStruckThrough: struckThrough[index],
            isMarked: isMarked[index],
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
    /// and a document renderer that skipped it left a user composing Hangul with
    /// nothing on screen until the syllable committed.
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
        if range.startColumn > 0,
           let head = index(row, range.startColumn - 1),
           Int(columnSpans[head]) > TerminalCellColumns.single {
            erase(head, frame: frame)
        }
        for column in range.cellRange {
            guard let index = index(row, column) else {
                continue
            }
            erase(index, frame: frame)
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
            guard let index = index(row, column) else {
                break
            }

            characters[index] = character
            columnSpans[index] = UInt8(clamping: width)
            foregrounds[index] = Self.markedForeground(
                utf16Offset: utf16Offset,
                utf16Length: String(character).utf16.count,
                frame: frame
            )
            isMarked[index] = true
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
    private mutating func erase(_ index: Int, frame: TerminalFrame) {
        characters[index] = Defaults.character
        columnSpans[index] = Defaults.columnSPAN
        foregrounds[index] = frame.defaultForeground
        underlined[index] = false
        struckThrough[index] = false
        shapes.removeValue(forKey: index)
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
            guard let index = index(decoration.row, decoration.column + offset) else {
                continue
            }

            switch decoration.kind {
            case .underline:
                underlined[index] = true
            case .strikethrough:
                struckThrough[index] = true
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
