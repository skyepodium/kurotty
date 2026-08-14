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
///
/// **One grid per frame, not one per row.** `Screen` is the entry point the
/// renderer uses: it indexes the frame's three flat arrays once and then answers
/// for every row. The earlier shape rebuilt that index inside each row-level
/// call, so patching a screen's worth of damaged rows indexed the whole frame
/// once per row — 97ms for 55 rows at 200 columns, measured, against 5ms for the
/// same screen built in one pass.
enum TerminalHTMLDocument {
    /// Class and attribute names, so the projector and the stylesheet cannot
    /// disagree about a string.
    enum Markup {
        static let rowClass = "trow"
        static let runClass = "trun"
        static let cursorClass = "tcursor"
        static let markedClass = "tmarked"
        static let underlineClass = "tul"
        static let strikethroughClass = "tst"

        static let rowOpen = "<div class=\"\(rowClass)\">"
        static let rowClose = "</div>"
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
        /// Decimal places for a shape's position and size inside its cell.
        static let percentDECIMALS = 4
        /// Decimal places for a colour's alpha channel.
        static let alphaDECIMALS = 3
    }

    // MARK: - Screens

    /// One frame, indexed once and ready to answer for any row.
    ///
    /// Held by the renderer for the length of a frame. Every row-level entry
    /// point below builds one of these and throws it away, which is correct for
    /// a test asking about a single row and quadratic for a renderer patching
    /// many.
    struct Screen {
        private let grid: Grid
        private let frame: TerminalFrame
        /// CSS colour strings for the colours this frame uses.
        ///
        /// A screen carries thousands of runs and a handful of colours, and
        /// formatting `rgba(...)` allocates a string every time. The cache is
        /// per-frame rather than global: it needs no invalidation key, no
        /// eviction policy and no owner beyond the frame being drawn, and a
        /// palette cannot outlive the screen that used it.
        private var colors: ColorStyles

        init(frame: TerminalFrame) {
            self.frame = frame
            grid = Grid(frame: frame)
            colors = ColorStyles()
        }

        var rowCOUNT: Int {
            max(frame.visibleRows, 0)
        }

        /// One row as the fewest runs that describe it.
        func runs(row: Int) -> [Run] {
            TerminalHTMLDocument.runs(row: row, grid: grid, frame: frame)
        }

        /// A row's spans, without the row element around them.
        ///
        /// The renderer patches a row's *children* rather than the row itself:
        /// swapping `outerHTML` destroys a live element and its layout box on
        /// every keystroke, while `innerHTML` keeps the box and reparses only
        /// the spans.
        mutating func contents(row: Int) -> String {
            var markup = ""
            markup.reserveCapacity(Layout.rowMarkupBYTES)
            append(row: row, to: &markup)
            return markup
        }

        /// Every visible row's inner markup, indexed by row.
        mutating func contents() -> [String] {
            (0..<rowCOUNT).map { contents(row: $0) }
        }

        /// One row's complete markup, element included.
        mutating func row(_ row: Int) -> String {
            var markup = Markup.rowOpen
            markup.reserveCapacity(Layout.rowMarkupBYTES)
            append(row: row, to: &markup)
            markup += Markup.rowClose
            return markup
        }

        private mutating func append(row: Int, to markup: inout String) {
            for run in runs(row: row) {
                TerminalHTMLDocument.append(run: run, to: &markup, colors: &colors)
            }
        }
    }

    private enum Layout {
        /// Starting capacity for one row's markup. A wide row of ordinary prose
        /// with a few colour changes lands near this; the string grows if the
        /// row is busier, which costs a reallocation rather than correctness.
        static let rowMarkupBYTES = 512
    }

    // MARK: - Rows

    /// Every row's markup as one string, ready to become the screen's
    /// `innerHTML`.
    ///
    /// Joined here rather than in the page: an array crosses the bridge as one
    /// JSON string per row and then has to be joined again on the other side,
    /// and neither of those costs buys anything.
    static func document(rowContents rows: [String]) -> String {
        var markup = ""
        markup.reserveCapacity(rows.count * Layout.rowMarkupBYTES)
        for contents in rows {
            markup += Markup.rowOpen
            markup += contents
            markup += Markup.rowClose
        }
        return markup
    }

    /// Every visible row's HTML, indexed by row.
    static func rows(frame: TerminalFrame) -> [String] {
        var screen = Screen(frame: frame)
        return (0..<screen.rowCOUNT).map { screen.row($0) }
    }

    /// One row's HTML, for a caller holding a single frame.
    static func row(_ row: Int, frame: TerminalFrame) -> String {
        var screen = Screen(frame: frame)
        return screen.row(row)
    }

    /// A row's spans without the row element around them.
    static func rowContents(_ row: Int, frame: TerminalFrame) -> String {
        var screen = Screen(frame: frame)
        return screen.contents(row: row)
    }

    /// Every visible row's inner markup, indexed by row.
    static func rowContents(frame: TerminalFrame) -> [String] {
        var screen = Screen(frame: frame)
        return screen.contents()
    }

    /// Cells, backgrounds and decorations indexed by position.
    ///
    /// The frame carries three flat arrays in whatever order the surface built
    /// them. Walking them per row would be quadratic on a full-damage frame,
    /// which is exactly the frame a TUI redraw produces.
    ///
    /// Flat arrays rather than dictionaries. The index is already an integer in
    /// a known range, so hashing it buys nothing, and a full screen meant tens
    /// of thousands of dictionary insertions per frame plus a hash on every
    /// lookup during coalescing.
    private struct Grid {
        private var characters: [Character]
        private var widths: [UInt8]
        private var foregrounds: [SIMD4<Float>]
        private var backgrounds: [SIMD4<Float>]
        private var underlines: [Bool]
        private var strikethroughs: [Bool]
        /// Sparse on purpose: geometry cells are rare even in a box-drawing TUI,
        /// and an array of empty arrays would cost more than it saves.
        private var shapes: [Int: [Shape]]
        let columns: Int
        let rows: Int

        private enum Defaults {
            static let character: Character = " "
            static let columnWIDTH: UInt8 = 1
        }

        init(frame: TerminalFrame) {
            columns = max(frame.columns, 1)
            rows = max(frame.visibleRows, 0)

            let cellCOUNT = columns * rows
            characters = Array(repeating: Defaults.character, count: cellCOUNT)
            widths = Array(repeating: Defaults.columnWIDTH, count: cellCOUNT)
            foregrounds = Array(repeating: frame.defaultForeground, count: cellCOUNT)
            backgrounds = Array(repeating: frame.defaultBackground, count: cellCOUNT)
            underlines = Array(repeating: false, count: cellCOUNT)
            strikethroughs = Array(repeating: false, count: cellCOUNT)
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
                foregrounds[index] = cell.foreground
                backgrounds[index] = cell.background
                widths[index] = Self.displayWidth(of: cell.character)
            }

            for decoration in frame.decorations {
                let span = max(decoration.width, 1)
                for offset in 0..<span {
                    guard let index = index(decoration.row, decoration.column + offset) else {
                        continue
                    }
                    switch decoration.kind {
                    case .underline:
                        underlines[index] = true
                    case .strikethrough:
                        strikethroughs[index] = true
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

        /// The flat index of a position, or nil when the frame reports one
        /// outside the screen it also reports. The arrays are sized from the
        /// frame's own dimensions, so an inconsistent frame must be dropped
        /// rather than allowed to index past the end.
        private func index(_ row: Int, _ column: Int) -> Int? {
            guard row >= 0, row < rows, column >= 0, column < columns else {
                return nil
            }
            return row * columns + column
        }

        func character(at index: Int) -> Character { characters[index] }
        func width(at index: Int) -> Int { Int(widths[index]) }
        func foreground(at index: Int) -> SIMD4<Float> { foregrounds[index] }
        func background(at index: Int) -> SIMD4<Float> { backgrounds[index] }
        func isUnderlined(at index: Int) -> Bool { underlines[index] }
        func isStruckThrough(at index: Int) -> Bool { strikethroughs[index] }
        func shapes(at index: Int) -> [Shape] { shapes[index] ?? [] }
        var hasShapes: Bool { !shapes.isEmpty }

        /// Columns a character occupies. East Asian wide and fullwidth forms
        /// take two, matching the two-cell head/continuation the Zig grid uses.
        static func displayWidth(of character: Character) -> UInt8 {
            guard let scalar = character.unicodeScalars.first else {
                return Defaults.columnWIDTH
            }
            return isWide(scalar) ? 2 : Defaults.columnWIDTH
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
        Screen(frame: frame).runs(row: row)
    }

    private static func runs(row: Int, grid: Grid, frame: TerminalFrame) -> [Run] {
        guard row >= 0, row < grid.rows else {
            return []
        }

        var runs: [Run] = []
        var column = 0
        let base = row * grid.columns
        let hasShapes = grid.hasShapes

        while column < grid.columns {
            let index = base + column
            let character = grid.character(at: index)
            let width = max(grid.width(at: index), 1)
            let foreground = grid.foreground(at: index)
            let background = grid.background(at: index)
            let isUnderlined = grid.isUnderlined(at: index)
            let isStruckThrough = grid.isStruckThrough(at: index)
            let shapes = hasShapes ? grid.shapes(at: index) : []

            // Extend the run in place when nothing visual changed. Comparing the
            // colours rather than a style identifier keeps this honest: two runs
            // that merge must be indistinguishable on screen.
            //
            // A cell carrying geometry never merges, in either direction: its
            // shapes are positioned inside one cell box, and a run two cells
            // wide would stretch them across both.
            //
            // The append is written through the subscript rather than through a
            // copied `runs.last`, because copying the run out and back leaves the
            // text string doubly referenced and every append then reallocates the
            // whole run — quadratic in the width of the line.
            let last = runs.count - 1
            if shapes.isEmpty,
               last >= 0,
               runs[last].shapes.isEmpty,
               runs[last].foreground == foreground,
               runs[last].background == background,
               runs[last].isUnderlined == isUnderlined,
               runs[last].isStruckThrough == isStruckThrough {
                runs[last].text.append(character)
                runs[last].columns += width
            } else {
                runs.append(Run(
                    text: String(character),
                    columns: width,
                    foreground: foreground,
                    background: background,
                    isUnderlined: isUnderlined,
                    isStruckThrough: isStruckThrough,
                    shapes: shapes
                ))
            }

            column += width
        }

        return runs
    }

    // MARK: - Markup

    private static func append(
        run: Run,
        to markup: inout String,
        colors: inout ColorStyles
    ) {
        markup += "<span class=\"\(Markup.runClass)"
        if run.isUnderlined {
            markup += " \(Markup.underlineClass)"
        }
        if run.isStruckThrough {
            markup += " \(Markup.strikethroughClass)"
        }

        markup += "\" style=\"color:"
        markup += colors.css(run.foreground)
        markup += ";background:"
        markup += colors.css(run.background)
        markup += ";width:calc(var(--cw) * \(run.columns))"

        guard !run.shapes.isEmpty else {
            markup += "\">"
            appendEscaped(run.text, to: &markup)
            markup += "</span>"
            return
        }

        // The cell becomes a positioning context and the shapes are laid inside
        // it as percentages, so they scale with the cell without knowing its
        // pixel size. The character itself is not drawn: the surface reports
        // geometry precisely for the characters it does not want drawn as text.
        markup += ";position:relative\">"
        for shape in run.shapes {
            markup += "<i style=\"position:absolute;left:"
            markup += percent(shape.x)
            markup += ";top:"
            markup += percent(shape.y)
            markup += ";width:"
            markup += percent(shape.width)
            markup += ";height:"
            markup += percent(shape.height)
            markup += ";background:"
            markup += colors.css(shape.color)
            markup += "\"></i>"
        }
        markup += "</span>"
    }

    private static func percent(_ value: Double) -> String {
        fixed(min(max(value, 0), 1) * 100, decimals: Geometry.percentDECIMALS) + "%"
    }

    /// A non-negative number with a fixed number of decimal places.
    ///
    /// `String(format:)` goes through Foundation and a locale for every call,
    /// and this is called several times per run on a screen that has thousands.
    static func fixed(_ value: Double, decimals: Int) -> String {
        var scale = 1
        for _ in 0..<decimals {
            scale *= 10
        }

        let scaled = Int((max(value, 0) * Double(scale)).rounded())
        let whole = scaled / scale
        var fraction = String(scaled % scale)
        if fraction.count < decimals {
            fraction = String(repeating: "0", count: decimals - fraction.count) + fraction
        }

        return "\(whole).\(fraction)"
    }

    /// CSS colour strings for one frame's palette.
    ///
    /// Bounded because a frame is not required to have a small palette: a true
    /// colour gradient would otherwise let the map grow to one entry per cell.
    /// Past the bound the formatting still happens, it is simply not remembered.
    private struct ColorStyles {
        /// Comfortably above a 256-colour palette plus a theme's own colours,
        /// and far below a screen's cell count.
        static let capacityCOUNT = 1024

        private var entries: [Key: String] = [:]

        private struct Key: Hashable {
            let red: UInt32
            let green: UInt32
            let blue: UInt32
            let alpha: UInt32

            init(_ color: SIMD4<Float>) {
                red = color.x.bitPattern
                green = color.y.bitPattern
                blue = color.z.bitPattern
                alpha = color.w.bitPattern
            }
        }

        mutating func css(_ color: SIMD4<Float>) -> String {
            let key = Key(color)
            if let cached = entries[key] {
                return cached
            }

            let formatted = TerminalHTMLDocument.css(color)
            if entries.count < Self.capacityCOUNT {
                entries[key] = formatted
            }
            return formatted
        }
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
        let alpha = fixed(Double(min(max(color.w, 0), 1)), decimals: Geometry.alphaDECIMALS)

        return "rgba(\(red),\(green),\(blue),\(alpha))"
    }

    private static func channel(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Escapes the characters that carry meaning in HTML.
    ///
    /// Terminal output is bytes from an arbitrary program, so a screen full of
    /// `<script>` is ordinary content, not an attack the renderer gets to
    /// assume away.
    static func escaped(_ value: String) -> String {
        var output = ""
        appendEscaped(value, to: &output)
        return output
    }

    /// One pass, and no allocation at all when nothing needs escaping.
    ///
    /// The previous shape ran five `replacingOccurrences` passes over every run,
    /// allocating five strings each time, on text that almost never contains any
    /// of the five characters.
    private static func appendEscaped(_ value: String, to output: inout String) {
        var plainStart = value.startIndex
        var index = value.startIndex

        while index < value.endIndex {
            let replacement: String
            switch value[index] {
            case "&": replacement = "&amp;"
            case "<": replacement = "&lt;"
            case ">": replacement = "&gt;"
            case "\"": replacement = "&quot;"
            case "'": replacement = "&#39;"
            default:
                index = value.index(after: index)
                continue
            }

            if plainStart < index {
                output += value[plainStart..<index]
            }
            output += replacement
            index = value.index(after: index)
            plainStart = index
        }

        guard plainStart != value.startIndex else {
            output += value  // Nothing was escaped; the whole run is one append.
            return
        }
        if plainStart < value.endIndex {
            output += value[plainStart...]
        }
    }
}
