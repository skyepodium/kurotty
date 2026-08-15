import AppKit
import Metal
import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// Measurement harness for the interactive-latency work.
///
/// These tests print wall-clock medians for the main-thread stages of the
/// keystroke->glyph and output->glyph paths so performance changes can report
/// before/after evidence. Assertions are deliberately loose sanity checks;
/// the printed numbers are the deliverable, not a timing gate.
final class TerminalRenderPerformanceBaselineTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["KUROTTY_RUN_RENDER_PERF_TESTS"] == "1" else {
            throw XCTSkip("Set KUROTTY_RUN_RENDER_PERF_TESTS=1 to run the render latency measurements")
        }
    }

    private enum Fixture {
        static let columns = 220
        static let rows = 55
        static let cellWidthPX: CGFloat = 8
        static let cellHeightPX: CGFloat = 17
        static let surfaceSize = NSSize(
            width: cellWidthPX * CGFloat(columns),
            height: cellHeightPX * CGFloat(rows)
        )
        static let echoSampleCount = 200
        static let scrollSampleCount = 120
        static let rendererSampleCount = 60
        static let endToEndSampleCount = 12
    }

    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((TerminalChildExit) -> Void)?

        func start(workingDirectory: String) {}
        func write(_ text: String) {}
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    private func median(_ samples: [Double]) -> Double {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private func report(_ label: String, microseconds samples: [Double]) {
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, (sorted.count * 9) / 10)]
        print(String(format: "[perf] %@ p50=%.1fus p90=%.1fus n=%d", label, p50, p90, samples.count))
    }

    private func timedMicroseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000
    }

    @MainActor
    private func makeFilledSurface(session: StubSession = StubSession()) -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(
            frame: NSRect(origin: .zero, size: Fixture.surfaceSize),
            session: session
        )
        // Resolve the renderer subview's constraints so frame updates reach the
        // Metal view's rebuild path the way they do inside a real window.
        surface.layoutSubtreeIfNeeded()
        surface.resizeGridForTesting(columns: Fixture.columns, rows: Fixture.rows)
        // Realistic mixed content: prose, a build-log style path, and one URL
        // every eighth row, plus scrollback so scrolling has somewhere to go.
        var lines: [String] = []
        for index in 0..<(Fixture.rows * 3) {
            if index % 8 == 0 {
                lines.append("[\(index)] fetching https://github.com/skyepodium/kurotty/releases/latest tag v0.1.\(index)")
            } else {
                lines.append("[\(index)] Sources/KurottyApp/TerminalSurfaceView.swift:\(index): note building module glyph atlas instance buffers for damage pass")
            }
        }
        surface.consumeTmuxRestoreOutputForTesting(Data(lines.joined(separator: "\r\n").utf8))
        return surface
    }

    /// Stage cost: one echoed character through parse + frame build + renderer
    /// update. This is the synchronous main-thread cost paid per keystroke echo.
    @MainActor
    func testMeasureSingleCharacterEchoAppendCost() throws {
        let surface = makeFilledSurface()
        var samples: [Double] = []
        samples.reserveCapacity(Fixture.echoSampleCount)
        for index in 0..<Fixture.echoSampleCount {
            let character = String(UnicodeScalar(UInt8(97 + index % 26)))
            samples.append(timedMicroseconds {
                surface.consumeTmuxRestoreOutputForTesting(Data(character.utf8))
            })
        }
        report("echo-append \(Fixture.columns)x\(Fixture.rows)", microseconds: samples)
        XCTAssertGreaterThan(median(samples), 0)
    }

    /// Stage cost: one wheel event while scrolled into scrollback. Every event
    /// is a full-damage frame rebuild today.
    @MainActor
    func testMeasureScrollWheelFullRebuildCost() throws {
        let surface = makeFilledSurface()
        var samples: [Double] = []
        samples.reserveCapacity(Fixture.scrollSampleCount)
        for index in 0..<Fixture.scrollSampleCount {
            let event = try discreteScrollEvent(deltaY: index % 2 == 0 ? 1 : -1)
            samples.append(timedMicroseconds {
                surface.scrollWheel(with: event)
            })
        }
        report("scroll-full-rebuild \(Fixture.columns)x\(Fixture.rows)", microseconds: samples)
        XCTAssertGreaterThan(median(samples), 0)
    }

    /// Stage cost: URL/file-path link detection over the visible rows, which
    /// `updateRendererFrame` runs on every frame today.
    @MainActor
    func testMeasureVisibleLinkDetectionCost() throws {
        let surface = makeFilledSurface()
        let rows = surface.interpreter.screen.cells
        var samples: [Double] = []
        samples.reserveCapacity(Fixture.rendererSampleCount)
        let context = TerminalFileLinkContext(
            workingDirectory: "/tmp",
            homeDirectory: NSHomeDirectory(),
            cachedExists: { _ in false },
            requestExistsProbe: { _ in }
        )
        var totalRanges = 0
        for _ in 0..<Fixture.rendererSampleCount {
            samples.append(timedMicroseconds {
                totalRanges += TerminalLinkRange.findAll(
                    in: rows,
                    startingRow: 0,
                    fileLinkContext: context
                ).count
            })
        }
        report("link-detection \(rows.count) rows", microseconds: samples)
        XCTAssertGreaterThan(totalRanges, 0)
    }

    /// Stage cost: renderer signature + instance-buffer rebuild for a changed
    /// frame versus the signature-only check for an identical frame.
    @MainActor
    func testMeasureMetalViewUpdateCost() throws {
        try measureMetalViewUpdate(columns: Fixture.columns, rows: Fixture.rows, sampleCount: 20)
    }

    /// Quarter-size grid to expose superlinear scaling in the rebuild path.
    @MainActor
    func testMeasureMetalViewUpdateCostQuarterGrid() throws {
        try measureMetalViewUpdate(columns: Fixture.columns / 4, rows: Fixture.rows, sampleCount: 20)
    }

    @MainActor
    private func measureMetalViewUpdate(columns: Int, rows: Int, sampleCount: Int) throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is not available")
        }
        let view = TerminalMetalView(font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        let size = NSSize(
            width: Fixture.cellWidthPX * CGFloat(columns),
            height: Fixture.cellHeightPX * CGFloat(rows)
        )
        view.frame = NSRect(origin: .zero, size: size)

        func makeFrame(generation: Int) -> TerminalFrame {
            var cells: [TerminalCell] = []
            cells.reserveCapacity(columns * rows)
            for row in 0..<rows {
                for column in 0..<columns where column % 5 != 4 {
                    let scalar = UnicodeScalar(UInt8(97 + (row + column + generation) % 26))
                    cells.append(TerminalCell(
                        character: Character(scalar),
                        column: column,
                        row: row,
                        foreground: DesignTokens.Color.terminalForeground,
                        background: DesignTokens.Color.terminalDefaultBackground
                    ))
                }
            }
            let dirtyRect = TerminalFrameRect(
                x: 0,
                y: 0,
                width: Double(size.width),
                height: Double(Fixture.cellHeightPX)
            )
            let cellSize = TerminalFrameSize(
                width: Double(Fixture.cellWidthPX),
                height: Double(Fixture.cellHeightPX)
            )
            let dirtyRects: [TerminalFrameRect] = [dirtyRect]
            return TerminalFrame(
                cells: cells,
                backgrounds: [],
                decorations: [],
                defaultForeground: DesignTokens.Color.terminalForeground,
                defaultBackground: DesignTokens.Color.terminalDefaultBackground,
                dirtyRows: [0],
                dirtyRects: dirtyRects,
                isFullDamage: false,
                cursorColumn: 0,
                cursorRow: 0,
                cursorBlinkOn: true,
                markedTextColumn: 0,
                markedText: "",
                markedTextSelectedRange: .none,
                columns: columns,
                visibleRows: rows,
                cellSize: cellSize,
                padding: .zero
            )
        }

        // Warm the glyph atlas so rasterization cost is not counted.
        view.update(frame: makeFrame(generation: 0))
        view.update(frame: makeFrame(generation: 1))

        var changedSamples: [Double] = []
        for generation in 2..<(2 + sampleCount) {
            let frame = makeFrame(generation: generation)
            changedSamples.append(timedMicroseconds {
                view.update(frame: frame)
            })
        }
        report("metal-update-changed \(columns)x\(rows)", microseconds: changedSamples)

        var unchangedSamples: [Double] = []
        let stableFrame = makeFrame(generation: 1_000)
        view.update(frame: stableFrame)
        for _ in 0..<sampleCount {
            unchangedSamples.append(timedMicroseconds {
                view.update(frame: stableFrame)
            })
        }
        report("metal-update-unchanged \(columns)x\(rows)", microseconds: unchangedSamples)
        XCTAssertGreaterThan(median(changedSamples), median(unchangedSamples))
    }

    /// End-to-end: PTY-output callback to visible screen-model change, spinning
    /// the main run loop the way the app does. Captures the queue hops and the
    /// output coalescing delay in front of parsing.
    @MainActor
    func testMeasureOutputCallbackToVisibleChangeLatency() throws {
        let session = StubSession()
        let surface = makeFilledSurface(session: session)
        let onOutput = try XCTUnwrap(session.onOutput)
        var samples: [Double] = []
        for index in 0..<Fixture.endToEndSampleCount {
            let marker = "zXq\(index)"
            let start = DispatchTime.now().uptimeNanoseconds
            onOutput(marker)
            let deadline = Date().addingTimeInterval(1.0)
            var observed = false
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.0002))
                if surface.tmuxRestoreStateForTesting.visibleLines.contains(where: { $0.contains(marker) }) {
                    observed = true
                    break
                }
            }
            XCTAssertTrue(observed, "output marker \(marker) never became visible")
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
        }
        report("output-to-visible end-to-end", microseconds: samples)
        XCTAssertGreaterThan(median(samples), 0)
    }

    private func discreteScrollEvent(deltaY: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        cgEvent.location = CGPoint(x: 10, y: 10)
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
