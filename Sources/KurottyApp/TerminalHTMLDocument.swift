import Foundation
import KurottyCore

/// Runs of a terminal row, as HTML.
///
/// Only markup. Indexing a frame belongs to `TerminalScreenIndex`, deciding
/// what a run is belongs to `TerminalRunCoalescer`, and the shapes drawn
/// instead of glyphs belong to `TerminalCellGeometry` — none of those are about
/// HTML, and a second backend should reuse them rather than answer the same
/// questions slightly differently. Cell width was derived three separate ways
/// before it was carried on the cell itself; this is the same hazard one layer
/// up.
///
/// **Explicit widths, because CSS does not know about cells.** A terminal is a
/// grid; text layout is not. Every run carries its width in cell units, so a
/// wide glyph occupies exactly two columns and nothing relies on the font
/// advancing the way the glyph atlas would.
enum TerminalHTMLDocument {
    /// The CSS custom properties everything positional is expressed in, so the
    /// stylesheet that declares them and the per-frame script that updates them
    /// cannot disagree about a name.
    ///
    /// The padding pair is not decoration. `TerminalSurfaceView` maps a click to
    /// a cell by subtracting the same padding it puts in the frame, so a
    /// document that draws row 0 at the origin puts every glyph a padding away
    /// from the cell the pointer resolves to — the selection then lands one
    /// column left of the text under the cursor.
    enum Variable {
        static let cellWidth = "--cw"
        static let cellHeight = "--ch"
        static let paddingX = "--px"
        static let paddingY = "--py"
        static let cursorBarWidth = "--cursor-bar"
        static let cursorUnderlineHeight = "--cursor-underline"
    }

    /// Class and attribute names, so the projector and the stylesheet cannot
    /// disagree about a string.
    enum Markup {
        /// The box that carries the grid's origin. Rows and the cursor both
        /// live inside it, so the frame's padding is applied exactly once.
        static let gridID = "grid"
        static let rowClass = "trow"
        static let runClass = "trun"
        static let underlineClass = "tul"
        static let strikethroughClass = "tst"
        /// Names the input method's composition rather than styling it, so the
        /// stylesheet decides what composing text looks like in one place.
        static let markedClass = "tmk"
        static let screenID = "screen"
        /// The layer pictures live in.
        ///
        /// Outside the rows, like the cursor, and for the same reason: a row's
        /// markup is replaced whenever that row changes, and an image spanning
        /// ten rows has no row to belong to. Positioned in the grid box so it
        /// shares the origin every cell is measured from.
        static let imagesID = "images"
        static let imageClass = "timg"
        static let imageIDPrefix = "i"
        static let cursorID = "cursor"

        static let rowOpen = "<div class=\"\(rowClass)\">"
        static let rowClose = "</div>"
    }

    private enum Layout {
        /// Starting capacity for one row's markup. A wide row of ordinary prose
        /// with a few colour changes lands near this; a busier row grows the
        /// string, which costs a reallocation rather than correctness.
        static let rowMarkupBYTES = 512
        /// Decimal places for a shape's position and size inside its cell.
        static let percentDECIMALS = 4
        /// Decimal places for a colour's alpha channel.
        static let alphaDECIMALS = 3
    }

    // MARK: - Screens

    /// One frame, indexed once, ready to answer for any row.
    ///
    /// Held by the renderer for the length of a frame. Every entry point that
    /// takes a `TerminalFrame` instead builds one of these and throws it away,
    /// which is right for a test asking about a single row and quadratic for a
    /// renderer patching many — measured at 97.5ms against 5.2ms for a 55x200
    /// screen.
    struct Screen {
        private let index: TerminalScreenIndex
        /// CSS colour strings for the colours this frame uses.
        ///
        /// A screen carries thousands of runs and a handful of colours, and
        /// formatting `rgba(...)` allocates a string every time. Per-frame
        /// rather than global: it needs no invalidation key, no eviction policy
        /// and no owner beyond the frame being drawn.
        private var colors = ColorStyles()

        init(frame: TerminalFrame) {
            index = TerminalScreenIndex(frame: frame)
        }

        var rowCOUNT: Int {
            index.rows
        }

        /// One row as the fewest runs that describe it.
        func runs(row: Int) -> [TerminalRunCoalescer.Run] {
            TerminalRunCoalescer.runs(row: row, in: index)
        }

        /// A row's spans, without the row element around them.
        ///
        /// The renderer patches a row's *children* rather than the row itself:
        /// swapping `outerHTML` discards a live element and its layout box on
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

    /// Every visible row's markup, indexed by row.
    static func rows(frame: TerminalFrame) -> [String] {
        var screen = Screen(frame: frame)
        return (0..<screen.rowCOUNT).map { screen.row($0) }
    }

    /// One row's markup, for a caller holding a single frame.
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

    /// The runs behind a row, for tests and for anything wanting them unwrapped.
    static func runs(row: Int, frame: TerminalFrame) -> [TerminalRunCoalescer.Run] {
        Screen(frame: frame).runs(row: row)
    }

    // MARK: - Runs

    /// One run appended in place.
    ///
    /// Appended rather than returned as a string per run: a screen has thousands
    /// of runs, and each returned string would be an allocation joined into
    /// another allocation.
    private static func append(
        run: TerminalRunCoalescer.Run,
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
        // The class names the composition rather than styling it. Metal draws
        // the preedit with the same pen it draws committed text with, and the
        // two renderers disagreeing about what composing text looks like is the
        // class of bug that keeps turning up here.
        if run.isMarked {
            markup += " \(Markup.markedClass)"
        }

        markup += "\" style=\"color:"
        markup += colors.css(run.foreground)
        markup += ";background:"
        markup += colors.css(run.background)
        markup += ";width:calc(var(\(Variable.cellWidth)) * \(run.columns))"

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
        fixed(min(max(value, 0), 1) * 100, decimals: Layout.percentDECIMALS) + "%"
    }

    // MARK: - Images

    /// One picture's inline style, in cell units.
    ///
    /// Position only. The source is set once, when the page first sees the
    /// identifier, because bytes that crossed the bridge on every frame would
    /// be re-sent for the whole time a picture stayed on screen — and a picture
    /// stays on screen for as long as anyone is looking at it.
    static func imageDeclaration(_ image: TerminalFrameImage) -> String {
        let cellWidth = "var(\(Variable.cellWidth))"
        let cellHeight = "var(\(Variable.cellHeight))"

        return "transform:translate("
            + "calc(\(cellWidth) * \(image.column)),calc(\(cellHeight) * \(image.row))"
            + ");width:calc(\(cellWidth) * \(image.columns))"
            + ";height:calc(\(cellHeight) * \(image.rows))"
    }

    /// The element id the page addresses one picture by.
    static func imageElementID(_ identifier: Int) -> String {
        "\(Markup.imageIDPrefix)\(identifier)"
    }

    /// What a screen reader says when it reaches a picture.
    ///
    /// The sender's file name when there is one, because that is the only
    /// description anything in a terminal ever carries. Without it the reader
    /// would announce an unlabelled graphic, which is worse than announcing a
    /// picture whose name is all anyone knows.
    static func imageDescription(_ image: TerminalFrameImage) -> String {
        guard let name = image.name, !name.isEmpty else {
            return "Inline image"
        }
        return "Inline image: \(name)"
    }

    // MARK: - Cursor

    /// The cursor element's inline style for this frame.
    ///
    /// The cell is the anchor, exactly as it is in `TerminalMetalView`: a block
    /// fills it, an underline is a rule on its bottom edge, and a bar is a rule
    /// on its leading edge. Everything is stated in the cell-metric and
    /// thickness custom properties, so a cursor stays the right size across a
    /// font change without the document being rebuilt.
    static func cursorDeclaration(frame: TerminalFrame) -> String {
        let cursor = TerminalCursorPlacement(frame: frame)
        let cellWidth = "var(\(Variable.cellWidth))"
        let cellHeight = "var(\(Variable.cellHeight))"
        let barWidth = "var(\(Variable.cursorBarWidth))"
        let underlineHeight = "var(\(Variable.cursorUnderlineHeight))"

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

    // MARK: - Formatting

    /// A frame colour as CSS.
    ///
    /// Components are clamped rather than trusted: a value slightly out of
    /// range would produce `rgba(256,…)`, which browsers drop entirely, so the
    /// cell would inherit a colour instead of showing a wrong one — and an
    /// inherited colour is much harder to notice than a wrong one.
    static func css(_ color: SIMD4<Float>) -> String {
        let red = channel(color.x)
        let green = channel(color.y)
        let blue = channel(color.z)
        let alpha = fixed(Double(min(max(color.w, 0), 1)), decimals: Layout.alphaDECIMALS)

        return "rgba(\(red),\(green),\(blue),\(alpha))"
    }

    private static func channel(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// A non-negative number with a fixed number of decimal places.
    ///
    /// `String(format:)` goes through Foundation and a locale on every call, and
    /// this is called several times per run on a screen that has thousands.
    static func fixed(_ value: Double, decimals: Int) -> String {
        var scale = 1
        for _ in 0..<decimals {
            scale *= 10
        }

        let scaled = Int((max(value, 0) * Double(scale)).rounded())
        var fraction = String(scaled % scale)
        if fraction.count < decimals {
            fraction = String(repeating: "0", count: decimals - fraction.count) + fraction
        }

        return "\(scaled / scale).\(fraction)"
    }

    /// CSS colour strings for one frame's palette.
    ///
    /// Bounded because a frame is not required to have a small palette: a true
    /// colour gradient would otherwise grow the map to one entry per cell. Past
    /// the bound the formatting still happens, it is simply not remembered.
    struct ColorStyles {
        /// Comfortably above a 256-colour palette plus a theme's own colours.
        private static let capacityCOUNT = 512
        private var entries: [Key: String] = [:]

        /// Float bit patterns rather than the vector itself, so the key is
        /// hashable without depending on floating-point equality.
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

    /// Escapes the characters that carry meaning in HTML.
    ///
    /// Terminal output is bytes from an arbitrary program, so a screen full of
    /// `<script>` is ordinary content rather than an attack the renderer gets
    /// to assume away. The ampersand goes first or it escapes the escapes.
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
