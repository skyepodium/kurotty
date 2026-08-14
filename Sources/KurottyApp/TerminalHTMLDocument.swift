import Foundation
import KurottyCore

/// Projects a terminal frame into HTML rows.
///
/// This is the whole rendering decision, and it is a pure function so it can be
/// measured and asserted without a web view, a GPU, or a window.
///
/// **Runs, not cells.** The obvious projection — one element per cell — is what
/// makes DOM terminals slow: a 200-column screen becomes 200 nodes per row and
/// 10,000 per screen, and every frame asks the layout engine to reflow all of
/// them. Adjacent cells that share a foreground, a background and a decoration
/// are emitted as one span instead, so an ordinary line of prose is a handful of
/// nodes and a line of solid colour is one. This is the single lever that
/// decides whether an HTML renderer is viable, which is why it is here in the
/// pure layer where a test can hold it to a node count.
///
/// **Explicit widths, because CSS does not know about cells.** A terminal is a
/// grid; text layout is not. Every run carries a width in cell units so a wide
/// glyph occupies exactly two columns and a run of combining marks cannot drift
/// the rest of the line. Nothing here relies on the font advancing the way the
/// glyph atlas would.
enum TerminalHTMLDocument {
    /// Class, attribute and custom-property names, so the projector and the
    /// stylesheet cannot disagree about a string.
    enum Markup {
        static let rowClass = "trow"
        static let rowIDPrefix = "r"
        static let runClass = "trun"
        static let cursorClass = "tcursor"
        static let markedClass = "tmarked"
        static let underlineClass = "tul"
        static let strikethroughClass = "tst"

        /// Cell metrics, published by the view once per size change so every
        /// run can be measured in cell units without knowing its pixel size.
        static let cellWidthVariable = "--cw"
        static let cellHeightVariable = "--ch"
        /// Thickness of the two DECSCUSR line shapes. The view resolves them
        /// from the same constants Metal draws from, because they are stated in
        /// device pixels and only the view knows the screen's density.
        static let cursorBarWidthVariable = "--cursor-bar"
        static let cursorUnderlineHeightVariable = "--cursor-underline"
    }

    /// A filled rectangle inside one cell, as a fraction of that cell.
    ///
    /// Block elements and box drawing are glyph *shapes* rather than text, and
    /// the terminal surface hands them over as geometry precisely because no
    /// font is involved. The atlas fills them directly; here they become
    /// positioned boxes.
    ///
    /// Stored in CSS orientation — `y` from the top — because the frame reports
    /// it from the bottom and converting once here beats converting at every
    /// use.
    struct Shape: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var color: SIMD4<Float>
    }

    /// One run of adjacent cells sharing every visual property.
    ///
    /// Kept as a value rather than emitted directly so coalescing can be tested
    /// against a count without parsing HTML back out of a string.
    struct Run: Equatable {
        var text: String
        /// Width in cells, which is not `text.count`: a wide glyph is one
        /// character occupying two columns.
        var columns: Int
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var isUnderlined: Bool
        var isStruckThrough: Bool
        /// True for cells the input method's preedit covers. It never merges
        /// with committed text, so the composition is always its own span.
        var isMarked: Bool = false
        /// Non-empty for a cell drawn as geometry rather than as text. Such a
        /// cell is always its own run: the shapes are positioned inside one
        /// cell box, so merging it with a neighbour would stretch them.
        var shapes: [Shape] = []
    }

    private enum Geometry {
        /// Line thickness for box drawing, as a fraction of the cell.
        ///
        /// The atlas derives its own from the font's underline thickness. This
        /// is a fraction instead because the document is sized in cell units
        /// and has no font metrics to ask.
        static let boxLineRATIO = 0.09
    }

    // MARK: - Rows

    /// Every visible row's HTML, indexed by row.
    ///
    /// The caller patches only the rows the frame reports dirty; producing all
    /// of them here keeps the projection total and lets a test compare a full
    /// screen against a damaged one.
    static func rows(frame: TerminalFrame) -> [String] {
        let grid = Grid(frame: frame)
        return (0..<max(frame.visibleRows, 0)).map { row in
            html(for: runs(row: row, grid: grid, frame: frame), row: row, frame: frame)
        }
    }

    /// One row's HTML, for the damage path.
    static func row(_ row: Int, frame: TerminalFrame) -> String {
        html(for: runs(row: row, grid: Grid(frame: frame), frame: frame), row: row, frame: frame)
    }

    /// A row's spans without the row element around them.
    ///
    /// The damage path replaces a row's *children* rather than the row itself.
    /// Swapping `outerHTML` destroys the element and builds a new one, so every
    /// keystroke discarded a live node and its layout box; setting `innerHTML`
    /// keeps the row and replaces what is inside it.
    static func rowContents(_ row: Int, frame: TerminalFrame) -> String {
        runs(row: row, grid: Grid(frame: frame), frame: frame)
            .map(span(for:))
            .joined()
    }

    /// Every visible row's inner markup, indexed by row.
    static func rowContents(frame: TerminalFrame) -> [String] {
        let grid = Grid(frame: frame)
        return (0..<max(frame.visibleRows, 0)).map { row in
            runs(row: row, grid: grid, frame: frame).map(span(for:)).joined()
        }
    }

    /// Cells, backgrounds and decorations indexed by position.
    ///
    /// The frame carries three flat arrays in whatever order the surface built
    /// them. Walking them per row would be quadratic on a full-damage frame,
    /// which is exactly the frame a TUI redraw produces.
    private struct Grid {
        private(set) var characters: [Int: Character] = [:]
        private(set) var widths: [Int: Int] = [:]
        private(set) var foregrounds: [Int: SIMD4<Float>] = [:]
        private(set) var backgrounds: [Int: SIMD4<Float>] = [:]
        private(set) var underlines: Set<Int> = []
        private(set) var strikethroughs: Set<Int> = []
        private(set) var shapes: [Int: [Shape]] = [:]
        private(set) var marked: Set<Int> = []
        let columns: Int

        init(frame: TerminalFrame) {
            columns = max(frame.columns, 1)

            for background in frame.backgrounds {
                backgrounds[key(background.row, background.column)] = background.color
            }

            for cell in frame.cells {
                let index = key(cell.row, cell.column)
                characters[index] = cell.character
                foregrounds[index] = cell.foreground
                backgrounds[index] = cell.background
                widths[index] = Self.displayWidth(of: cell.character)
            }

            for decoration in frame.decorations {
                let span = max(decoration.width, 1)
                for offset in 0..<span {
                    let index = key(decoration.row, decoration.column + offset)
                    switch decoration.kind {
                    case .underline:
                        underlines.insert(index)
                    case .strikethrough:
                        strikethroughs.insert(index)
                    case let .blockElement(x, y, width, height):
                        // The frame measures y from the bottom of the cell;
                        // CSS measures from the top.
                        shapes[index, default: []].append(Shape(
                            x: x,
                            y: 1 - y - height,
                            width: width,
                            height: height,
                            color: decoration.color
                        ))
                    case let .boxDrawing(left, right, up, down):
                        shapes[index, default: []].append(contentsOf: Self.boxShapes(
                            left: left, right: right, up: up, down: down,
                            color: decoration.color
                        ))
                    }
                }
            }

            overlayMarkedText(frame: frame)
        }

        /// Lays the input method's preedit over the row the composition sits on.
        ///
        /// The frame carries the composition rather than the screen buffer,
        /// because `setMarkedText` is preedit state and must never be written
        /// to the terminal as committed text. Drawing it is therefore the
        /// renderer's job, and until now this renderer did not do it: a user
        /// composing Hangul saw nothing until the syllable committed.
        ///
        /// The cells underneath are dropped rather than drawn behind, which is
        /// what `TerminalMetalView` does with the same range: the composition
        /// replaces what is on the line for as long as it lasts.
        private mutating func overlayMarkedText(frame: TerminalFrame) {
            guard let range = frame.markedTextRenderRange,
                  frame.cursorRow >= 0
            else {
                return
            }

            let row = frame.cursorRow

            // A wide cell whose head sits just before the composition would
            // otherwise be stepped over the first covered column and shift the
            // preedit one cell to the right, so it goes as well.
            if range.startColumn > 0 {
                let head = key(row, range.startColumn - 1)
                if (widths[head] ?? 1) > 1 {
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

                // The same width function the range was laid out with. Asking a
                // second one would let the two disagree and run the composition
                // off the end of its own range.
                let width = max(character.terminalColumnWidth, 1)
                guard column + width <= range.endColumn else {
                    break
                }

                let index = key(row, column)
                characters[index] = character
                widths[index] = width
                foregrounds[index] = TerminalHTMLDocument.markedForeground(
                    utf16Offset: utf16Offset,
                    utf16Length: String(character).utf16.count,
                    frame: frame
                )
                marked.insert(index)
                column += width
            }
        }

        /// Drops whatever was drawn in a cell, leaving its background alone.
        private mutating func erase(_ index: Int) {
            characters.removeValue(forKey: index)
            widths.removeValue(forKey: index)
            foregrounds.removeValue(forKey: index)
            shapes.removeValue(forKey: index)
            underlines.remove(index)
            strikethroughs.remove(index)
        }

        /// Box drawing as up to four bars meeting at the centre of the cell.
        ///
        /// Each arm runs from the cell edge to just past the middle, so a
        /// corner joins without a notch where the two bars meet.
        static func boxShapes(
            left: Bool, right: Bool, up: Bool, down: Bool,
            color: SIMD4<Float>
        ) -> [Shape] {
            let thickness = Geometry.boxLineRATIO
            let near = (1 - thickness) / 2
            let far = near + thickness
            var shapes: [Shape] = []

            if left {
                shapes.append(Shape(x: 0, y: near, width: far, height: thickness, color: color))
            }
            if right {
                shapes.append(Shape(x: near, y: near, width: 1 - near, height: thickness, color: color))
            }
            if up {
                shapes.append(Shape(x: near, y: 0, width: thickness, height: far, color: color))
            }
            if down {
                shapes.append(Shape(x: near, y: near, width: thickness, height: 1 - near, color: color))
            }

            return shapes
        }

        func key(_ row: Int, _ column: Int) -> Int {
            row * columns + column
        }

        /// Columns a character occupies. East Asian wide and fullwidth forms
        /// take two, matching the two-cell head/continuation the Zig grid uses.
        static func displayWidth(of character: Character) -> Int {
            guard let scalar = character.unicodeScalars.first else {
                return 1
            }
            return isWide(scalar) ? 2 : 1
        }

        private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x1100...0x115F,          // Hangul Jamo initial
                 0x2E80...0x303E,          // CJK radicals, Kangxi, punctuation
                 0x3041...0x33FF,          // Kana through CJK compatibility
                 0x3400...0x4DBF,          // CJK extension A
                 0x4E00...0x9FFF,          // CJK unified
                 0xA000...0xA4CF,          // Yi
                 0xAC00...0xD7A3,          // Hangul syllables
                 0xF900...0xFAFF,          // CJK compatibility ideographs
                 0xFE30...0xFE6F,          // CJK compatibility forms
                 0xFF00...0xFF60,          // Fullwidth forms
                 0xFFE0...0xFFE6,
                 0x1F300...0x1F64F,        // Emoji
                 0x1F900...0x1F9FF,
                 0x20000...0x3FFFD:        // CJK extensions B and beyond
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Coalescing

    /// One row as the fewest runs that describe it.
    static func runs(row: Int, frame: TerminalFrame) -> [Run] {
        runs(row: row, grid: Grid(frame: frame), frame: frame)
    }

    private static func runs(row: Int, grid: Grid, frame: TerminalFrame) -> [Run] {
        var runs: [Run] = []
        var column = 0

        while column < grid.columns {
            let index = grid.key(row, column)
            let character = grid.characters[index] ?? " "
            let width = max(grid.widths[index] ?? 1, 1)
            let foreground = grid.foregrounds[index] ?? frame.defaultForeground
            let background = grid.backgrounds[index] ?? frame.defaultBackground
            let isUnderlined = grid.underlines.contains(index)
            let isStruckThrough = grid.strikethroughs.contains(index)
            let isMarked = grid.marked.contains(index)
            let shapes = grid.shapes[index] ?? []

            // Extend the run in place when nothing visual changed. Comparing the
            // colours rather than a style identifier keeps this honest: two runs
            // that merge must be indistinguishable on screen.
            //
            // A cell carrying geometry never merges, in either direction: its
            // shapes are positioned inside one cell box, and a run two cells
            // wide would stretch them across both.
            if shapes.isEmpty,
               var last = runs.last,
               last.shapes.isEmpty,
               last.foreground == foreground,
               last.background == background,
               last.isUnderlined == isUnderlined,
               last.isStruckThrough == isStruckThrough,
               last.isMarked == isMarked {
                last.text.append(character)
                last.columns += width
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(
                    text: String(character),
                    columns: width,
                    foreground: foreground,
                    background: background,
                    isUnderlined: isUnderlined,
                    isStruckThrough: isStruckThrough,
                    isMarked: isMarked,
                    shapes: shapes
                ))
            }

            column += width
        }

        return runs
    }

    // MARK: - Marked text

    /// The colour one preedit character is drawn in.
    ///
    /// The input method selects a sub-range of its own composition — in Hangul,
    /// the syllable currently being built — and that sub-range is what tells the
    /// user where the next keystroke lands. `TerminalMetalView` distinguishes it
    /// by drawing it in the selection foreground while the rest of the
    /// composition keeps the screen's, and this matches that rather than
    /// inventing a second convention.
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

    // MARK: - Cursor

    /// Where the caret sits and what shape DECSCUSR gave it.
    ///
    /// `blinks` is deliberately absent: the surface has already folded the blink
    /// phase into `cursorBlinkOn` before the frame is built, so a renderer that
    /// consulted it as well would blink the cursor twice.
    struct Cursor: Equatable {
        var column: Int
        var row: Int
        var shape: TerminalCursorStyle.Shape
        var isVisible: Bool
    }

    static func cursor(frame: TerminalFrame) -> Cursor {
        Cursor(
            column: max(0, caretColumn(frame: frame)),
            row: max(0, frame.cursorRow),
            shape: frame.cursorStyle.shape,
            isVisible: frame.cursorBlinkOn && frame.cursorRow >= 0
        )
    }

    /// The cursor element's inline style for this frame.
    ///
    /// The cell is the anchor, exactly as it is in `TerminalMetalView`: a block
    /// fills it, an underline is a rule on its bottom edge, and a bar is a rule
    /// on its leading edge. Everything is stated in the cell-metric and
    /// thickness custom properties, so a cursor stays the right size across a
    /// font change without the document being rebuilt.
    static func cursorDeclaration(frame: TerminalFrame) -> String {
        let cursor = cursor(frame: frame)
        let cellWidth = "var(\(Markup.cellWidthVariable))"
        let cellHeight = "var(\(Markup.cellHeightVariable))"
        let barWidth = "var(\(Markup.cursorBarWidthVariable))"
        let underlineHeight = "var(\(Markup.cursorUnderlineHeightVariable))"

        let x = "calc(\(cellWidth) * \(cursor.column))"
        var y = "calc(\(cellHeight) * \(cursor.row))"
        var width = cellWidth
        var height = cellHeight

        switch cursor.shape {
        case .block:
            break
        case .underline:
            height = underlineHeight
            y = "calc(\(cellHeight) * \(cursor.row) + \(cellHeight) - \(underlineHeight))"
        case .bar:
            width = barWidth
        }

        return "transform:translate(\(x),\(y));"
            + "width:\(width);height:\(height);"
            + "opacity:\(cursor.isVisible ? 1 : 0)"
    }

    /// The column the caret occupies, which is inside the composition while one
    /// is being typed: the input method's selected sub-range says where the next
    /// keystroke lands, and a caret parked after the whole preedit would say
    /// something else.
    private static func caretColumn(frame: TerminalFrame) -> Int {
        guard let range = frame.markedTextRenderRange else {
            return frame.cursorColumn
        }
        return range.cursorColumn(
            in: frame.markedText,
            selectedUTF16Location: frame.markedTextSelectedRange.location
        )
    }

    // MARK: - Markup

    private static func html(for runs: [Run], row: Int, frame: TerminalFrame) -> String {
        var markup = "<div class=\"\(Markup.rowClass)\" id=\"\(Markup.rowIDPrefix)\(row)\">"

        for run in runs {
            markup += span(for: run)
        }

        markup += "</div>"
        return markup
    }

    private static func span(for run: Run) -> String {
        var classes = Markup.runClass
        if run.isUnderlined {
            classes += " \(Markup.underlineClass)"
        }
        if run.isStruckThrough {
            classes += " \(Markup.strikethroughClass)"
        }
        // The class names the composition rather than styling it. Metal draws
        // the preedit with the same pen it draws committed text with, and the
        // two renderers disagreeing about what composing text looks like is the
        // class of bug this whole branch keeps finding.
        if run.isMarked {
            classes += " \(Markup.markedClass)"
        }

        var style = "color:\(css(run.foreground));background:\(css(run.background));"
            + "width:calc(var(\(Markup.cellWidthVariable)) * \(run.columns))"

        guard !run.shapes.isEmpty else {
            return "<span class=\"\(classes)\" style=\"\(style)\">\(escaped(run.text))</span>"
        }

        // The cell becomes a positioning context and the shapes are laid inside
        // it as percentages, so they scale with the cell without knowing its
        // pixel size. The character itself is not drawn: the surface reports
        // geometry precisely for the characters it does not want drawn as text.
        style += ";position:relative"
        let boxes = run.shapes.map { shape in
            "<i style=\"position:absolute;"
                + "left:\(percent(shape.x));top:\(percent(shape.y));"
                + "width:\(percent(shape.width));height:\(percent(shape.height));"
                + "background:\(css(shape.color))\"></i>"
        }.joined()

        return "<span class=\"\(classes)\" style=\"\(style)\">\(boxes)</span>"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.4f%%", min(max(value, 0), 1) * 100)
    }

    /// A frame colour as CSS.
    ///
    /// The frame carries premultiplied-looking float components in 0...1; they
    /// are clamped rather than trusted, because a colour that arrives slightly
    /// out of range would otherwise produce `rgba(256,…)`, which a browser drops
    /// entirely and renders as inherited — a silent wrong colour rather than a
    /// visible one.
    static func css(_ color: SIMD4<Float>) -> String {
        let red = channel(color.x)
        let green = channel(color.y)
        let blue = channel(color.z)
        let alpha = min(max(color.w, 0), 1)

        return "rgba(\(red),\(green),\(blue),\(String(format: "%.3f", alpha)))"
    }

    private static func channel(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Escapes the characters that carry meaning in HTML.
    ///
    /// Terminal output is bytes from an arbitrary program, so a screen full of
    /// `<script>` is ordinary content, not an attack the renderer gets to
    /// assume away. The ampersand goes first or it escapes the escapes.
    static func escaped(_ value: String) -> String {
        var output = value.replacingOccurrences(of: "&", with: "&amp;")
        output = output.replacingOccurrences(of: "<", with: "&lt;")
        output = output.replacingOccurrences(of: ">", with: "&gt;")
        output = output.replacingOccurrences(of: "\"", with: "&quot;")
        output = output.replacingOccurrences(of: "'", with: "&#39;")
        return output
    }
}
