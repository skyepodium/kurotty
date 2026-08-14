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
    /// Class and attribute names, so the projector and the stylesheet cannot
    /// disagree about a string.
    enum Markup {
        static let rowClass = "trow"
        static let rowIDPrefix = "r"
        static let runClass = "trun"
        static let cursorClass = "tcursor"
        static let markedClass = "tmarked"
        static let underlineClass = "tul"
        static let strikethroughClass = "tst"
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
                // A decoration spans cells, and box drawing and block elements
                // are glyph shapes the atlas draws rather than text styles. Only
                // the two that are text styles cross into HTML; the others are
                // left to the character already in the cell.
                let span = max(decoration.width, 1)
                for offset in 0..<span {
                    let index = key(decoration.row, decoration.column + offset)
                    switch decoration.kind {
                    case .underline: underlines.insert(index)
                    case .strikethrough: strikethroughs.insert(index)
                    case .boxDrawing, .blockElement: continue
                    }
                }
            }
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

            // Extend the run in place when nothing visual changed. Comparing the
            // colours rather than a style identifier keeps this honest: two runs
            // that merge must be indistinguishable on screen.
            if var last = runs.last,
               last.foreground == foreground,
               last.background == background,
               last.isUnderlined == isUnderlined,
               last.isStruckThrough == isStruckThrough {
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
                    isStruckThrough: isStruckThrough
                ))
            }

            column += width
        }

        return runs
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

        let style = "color:\(css(run.foreground));background:\(css(run.background));width:calc(var(--cw) * \(run.columns))"

        return "<span class=\"\(classes)\" style=\"\(style)\">\(escaped(run.text))</span>"
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
