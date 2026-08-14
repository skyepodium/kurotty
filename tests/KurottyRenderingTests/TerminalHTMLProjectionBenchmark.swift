import XCTest
import KurottyCore
@testable import KurottyApp

/// Times the pure projection — frame in, markup out — with no web view involved.
///
/// The end-to-end probe (`KUROTTY_RENDER_LATENCY`) measures submit-to-composite,
/// which folds Swift projection, JSON encoding, the process hop, HTML parsing and
/// two animation frames into one number. That is the right number to report and
/// the wrong number to optimise against: it cannot say which half moved. This
/// isolates the Swift half so a change to the projection can be attributed.
///
/// Off unless `KUROTTY_HTML_PROJECTION_BENCH=1`. A timing assertion in the normal
/// suite would be a flake on a shared runner, and this prints rather than asserts
/// for the same reason.
final class TerminalHTMLProjectionBenchmark: XCTestCase {
    private enum Workload {
        /// A large-but-ordinary window: the measured configuration on this
        /// branch was 55 rows, and 200 columns is a wide split.
        static let columns = 200
        static let rows = 55
        /// Enough repetitions that a per-frame cost is resolvable above the
        /// clock, few enough that the run stays interactive.
        static let iterationCOUNT = 200
        static let microsecondsPerSecondRATIO = 1_000_000.0
        static let environmentVariable = "KUROTTY_HTML_PROJECTION_BENCH"
    }

    private enum Palette {
        static let foreground = SIMD4<Float>(0.8, 0.8, 0.8, 1)
        static let background = SIMD4<Float>(0.05, 0.05, 0.07, 1)
        static let accent = SIMD4<Float>(0.4, 0.8, 1, 1)
        static let warning = SIMD4<Float>(0.9, 0.6, 0.2, 1)
    }

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment[Workload.environmentVariable] == "1"
    }

    // MARK: - Fixtures

    /// A screen of prose with a few colour changes per line.
    ///
    /// A single-colour screen would coalesce to one run per row and measure a
    /// best case no terminal produces; a per-cell colour would measure a worst
    /// case no terminal produces either. Four runs a line is what a prompt, a
    /// path and a diff look like.
    private func screenCells(offset: Int) -> [TerminalCell] {
        var cells: [TerminalCell] = []
        cells.reserveCapacity(Workload.rows * Workload.columns)

        for row in 0..<Workload.rows {
            let text = Array(
                "row \(row + offset) the quick brown fox jumps over the lazy dog "
                    + String(repeating: "abcdefghij ", count: 16)
            ).prefix(Workload.columns)

            for (column, character) in text.enumerated() {
                let foreground: SIMD4<Float>
                switch column / 50 {
                case 0: foreground = Palette.foreground
                case 1: foreground = Palette.accent
                case 2: foreground = Palette.warning
                default: foreground = Palette.foreground
                }

                cells.append(TerminalCell(
                    character: character,
                    column: column,
                    row: row,
                    foreground: foreground,
                    background: Palette.background
                ))
            }
        }

        return cells
    }

    private func frame(offset: Int, dirtyRows: [Int], isFullDamage: Bool) -> TerminalFrame {
        TerminalFrame(
            cells: screenCells(offset: offset),
            backgrounds: [],
            decorations: [],
            defaultForeground: Palette.foreground,
            defaultBackground: Palette.background,
            dirtyRows: dirtyRows,
            dirtyRects: [],
            isFullDamage: isFullDamage,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: TerminalTextSelectionRange(location: 0, length: 0),
            columns: Workload.columns,
            visibleRows: Workload.rows,
            cellSize: TerminalFrameSize(width: 8, height: 16),
            padding: TerminalFramePoint(x: 0, y: 0)
        )
    }

    // MARK: - Measurements

    func testFullScreenProjectionCost() throws {
        try XCTSkipUnless(isEnabled, "set \(Workload.environmentVariable)=1 to run")

        let frames = (0..<8).map { frame(offset: $0, dirtyRows: [], isFullDamage: true) }
        var sink = 0

        let elapsed = time {
            for iteration in 0..<Workload.iterationCOUNT {
                sink += TerminalHTMLDocument.rows(frame: frames[iteration % frames.count]).count
            }
        }

        report("full screen rows(frame:)", elapsed: elapsed, sink: sink)
    }

    /// The row-at-a-time entry points, which index the whole frame per call.
    ///
    /// Kept as a measurement because it is the trap: convenient to call in a
    /// loop, and quadratic when a screen's worth of rows is patched. The
    /// renderer builds one `Screen` and asks it for every row instead.
    func testEveryRowPatchedIndividually() throws {
        try XCTSkipUnless(isEnabled, "set \(Workload.environmentVariable)=1 to run")

        let dirty = Array(0..<Workload.rows)
        let frames = (0..<8).map { frame(offset: $0, dirtyRows: dirty, isFullDamage: false) }
        var sink = 0

        let elapsed = time {
            for iteration in 0..<Workload.iterationCOUNT {
                let frame = frames[iteration % frames.count]
                for row in dirty {
                    sink += TerminalHTMLDocument.rowContents(row, frame: frame).count
                }
            }
        }

        report("every row via rowContents(_:frame:)", elapsed: elapsed, sink: sink)
    }

    /// What the renderer actually does per frame: index the frame once, project
    /// every row, and diff the result against what the page is showing.
    func testRendererFramePath() throws {
        try XCTSkipUnless(isEnabled, "set \(Workload.environmentVariable)=1 to run")

        let frames = (0..<8).map { frame(offset: $0, dirtyRows: [], isFullDamage: true) }
        var rendered: [String] = []
        var sink = 0

        let elapsed = time {
            for iteration in 0..<Workload.iterationCOUNT {
                var screen = TerminalHTMLDocument.Screen(frame: frames[iteration % frames.count])
                let rows = screen.contents()
                sink += TerminalHTMLRowDiff.plan(from: rendered, to: rows).rows.count
                rendered = rows
            }
        }

        report("Screen.contents() plus row diff", elapsed: elapsed, sink: sink)
    }

    private func time(_ body: () -> Void) -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }

    private func report(_ name: String, elapsed: Double, sink: Int) {
        let perFrame = elapsed / Double(Workload.iterationCOUNT) * Workload.microsecondsPerSecondRATIO
        print(String(
            format: "projection [%@] %d frames in %.3fs = %.0fus/frame (sink %d)",
            name,
            Workload.iterationCOUNT,
            elapsed,
            perFrame,
            sink
        ))
    }
}
