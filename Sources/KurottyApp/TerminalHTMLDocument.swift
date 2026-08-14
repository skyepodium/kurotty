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
    }

    /// Class and attribute names, so the projector and the stylesheet cannot
    /// disagree about a string.
    enum Markup {
        /// The box that carries the grid's origin. Rows and the cursor both
        /// live inside it, so the frame's padding is applied exactly once.
        static let gridID = "grid"
        static let rowClass = "trow"
        static let rowIDPrefix = "r"
        static let runClass = "trun"
        static let underlineClass = "tul"
        static let strikethroughClass = "tst"
        static let screenID = "screen"
        static let cursorID = "cursor"
    }

    // MARK: - Rows

    /// Every visible row's markup, indexed by row.
    static func rows(frame: TerminalFrame) -> [String] {
        let screen = TerminalScreenIndex(frame: frame)
        return (0..<screen.rows).map { row in
            element(row: row, contents: contents(row: row, in: screen))
        }
    }

    /// One row's markup, for the damage path.
    static func row(_ row: Int, frame: TerminalFrame) -> String {
        element(row: row, contents: rowContents(row, frame: frame))
    }

    /// A row's spans without the row element around them.
    ///
    /// The damage path replaces a row's *children* rather than the row itself:
    /// swapping `outerHTML` discards a live element and its layout box on every
    /// keystroke, while `innerHTML` keeps the box and reparses only the spans.
    static func rowContents(_ row: Int, frame: TerminalFrame) -> String {
        contents(row: row, in: TerminalScreenIndex(frame: frame))
    }

    /// Every visible row's inner markup, indexed by row.
    static func rowContents(frame: TerminalFrame) -> [String] {
        let screen = TerminalScreenIndex(frame: frame)
        return (0..<screen.rows).map { contents(row: $0, in: screen) }
    }

    /// The runs behind a row, for tests and for anything wanting them unwrapped.
    static func runs(row: Int, frame: TerminalFrame) -> [TerminalRunCoalescer.Run] {
        TerminalRunCoalescer.runs(row: row, in: TerminalScreenIndex(frame: frame))
    }

    private static func contents(row: Int, in screen: TerminalScreenIndex) -> String {
        TerminalRunCoalescer.runs(row: row, in: screen).map(span(for:)).joined()
    }

    private static func element(row: Int, contents: String) -> String {
        "<div class=\"\(Markup.rowClass)\" id=\"\(Markup.rowIDPrefix)\(row)\">\(contents)</div>"
    }

    // MARK: - Runs

    private static func span(for run: TerminalRunCoalescer.Run) -> String {
        var classes = Markup.runClass
        if run.isUnderlined {
            classes += " \(Markup.underlineClass)"
        }
        if run.isStruckThrough {
            classes += " \(Markup.strikethroughClass)"
        }

        let sizing = "color:\(css(run.foreground));background:\(css(run.background))"
            + ";width:calc(var(--cw) * \(run.columns))"

        guard !run.shapes.isEmpty else {
            return "<span class=\"\(classes)\" style=\"\(sizing)\">\(escaped(run.text))</span>"
        }

        // The cell becomes a positioning context and the shapes are laid inside
        // it as percentages, so they scale with the cell without knowing its
        // pixel size. The character itself is not drawn: the surface reports
        // geometry precisely for the characters it does not want drawn as text.
        return "<span class=\"\(classes)\" style=\"\(sizing);position:relative\">"
            + run.shapes.map(fill(for:)).joined()
            + "</span>"
    }

    private static func fill(for shape: TerminalCellGeometry.Shape) -> String {
        "<i style=\"position:absolute"
            + ";left:\(percent(shape.x));top:\(percent(shape.y))"
            + ";width:\(percent(shape.width));height:\(percent(shape.height))"
            + ";background:\(css(shape.color))\"></i>"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.4f%%", min(max(value, 0), 1) * 100)
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
        let alpha = min(max(color.w, 0), 1)

        return "rgba(\(red),\(green),\(blue),\(String(format: "%.3f", alpha)))"
    }

    private static func channel(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Escapes the characters that carry meaning in HTML.
    ///
    /// Terminal output is bytes from an arbitrary program, so a screen full of
    /// `<script>` is ordinary content rather than an attack the renderer gets
    /// to assume away. The ampersand goes first or it escapes the escapes.
    static func escaped(_ value: String) -> String {
        var output = value.replacingOccurrences(of: "&", with: "&amp;")
        output = output.replacingOccurrences(of: "<", with: "&lt;")
        output = output.replacingOccurrences(of: ">", with: "&gt;")
        output = output.replacingOccurrences(of: "\"", with: "&quot;")
        output = output.replacingOccurrences(of: "'", with: "&#39;")
        return output
    }
}
