import Foundation
import KurottyCore

/// Adjacent cells that look the same, collapsed into one run.
///
/// This is the decision that makes a document renderer viable at all, which is
/// why it is one type on its own rather than a loop inside a projector. One
/// element per cell turns an 80-column screen into 1,920 nodes and asks the
/// layout engine to reflow all of them every frame; a run of prose is a handful
/// instead. Isolated here, the ratio can be measured and held to a bound
/// without a renderer, a screen or a GPU.
///
/// Free of HTML. A run is "these columns share a foreground, a background and a
/// decoration" — true of any backend that batches, including a canvas path that
/// would set fill style once per run rather than once per cell.
enum TerminalRunCoalescer {
    /// One stretch of a row that can be drawn in a single operation.
    struct Run: Equatable {
        var text: String
        /// Width in cells, which is not `text.count`: a wide glyph is one
        /// character occupying two columns.
        var columns: Int
        var foreground: SIMD4<Float>
        var background: SIMD4<Float>
        var isUnderlined: Bool
        var isStruckThrough: Bool
        /// Whether this is an input method's composition rather than committed
        /// screen content.
        var isMarked: Bool = false
        /// Non-empty for a cell drawn as geometry rather than as text.
        var shapes: [TerminalCellGeometry.Shape] = []
    }

    /// One row as the fewest runs that describe it.
    static func runs(row: Int, in screen: TerminalScreenIndex) -> [Run] {
        var runs: [Run] = []
        var column = 0

        while column < screen.columns {
            let cell = screen.attributes(at: screen.key(row, column))
            column += cell.columns

            guard var last = runs.last, canExtend(last, with: cell) else {
                runs.append(Run(
                    text: String(cell.character),
                    columns: cell.columns,
                    foreground: cell.foreground,
                    background: cell.background,
                    isUnderlined: cell.isUnderlined,
                    isStruckThrough: cell.isStruckThrough,
                    isMarked: cell.isMarked,
                    shapes: cell.shapes
                ))
                continue
            }

            last.text.append(cell.character)
            last.columns += cell.columns
            runs[runs.count - 1] = last
        }

        return runs
    }

    /// Whether a cell can join the run before it.
    ///
    /// Compares the colours rather than a style identifier, because two runs
    /// that merge must be indistinguishable on screen and an identifier can
    /// claim more sameness than the pixels have.
    ///
    /// A cell carrying geometry never merges, in either direction: its shapes
    /// are positioned inside one cell box, and a run two cells wide would
    /// stretch them across both.
    private static func canExtend(_ run: Run, with cell: TerminalScreenIndex.Attributes) -> Bool {
        guard cell.shapes.isEmpty, run.shapes.isEmpty else {
            return false
        }
        guard run.foreground == cell.foreground, run.background == cell.background else {
            return false
        }
        guard run.isUnderlined == cell.isUnderlined else {
            return false
        }
        guard run.isStruckThrough == cell.isStruckThrough else {
            return false
        }

        // A composition and the text beside it must stay separable even when
        // they are the same colour, so a renderer can mark one and not the
        // other.
        return run.isMarked == cell.isMarked
    }
}
