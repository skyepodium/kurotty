import AppKit
import KurottyCore
import XCTest

@testable import KurottyApp

/// The terminal pane is a rounded card now, and rounding a terminal is the one
/// piece of chrome that can silently eat content. Two ways it goes wrong:
///
/// 1. The mask shaves the corner cells, so the first and last glyph of the top
///    and bottom rows lose a slice.
/// 2. The grid is inset to clear the arc but the PTY is never told, so the
///    shell believes it has columns it cannot draw into and wraps early.
///
/// Both are measured here against the geometry the app actually ships: the cell
/// rects come from `TerminalSurfaceView.cursorCellRectInViewCoordinates` (the
/// same formula the Metal view draws with) and the grid comes out of the
/// terminal's own XTWINOPS replies, which are routed through the single
/// `terminalMetrics()` path that also feeds `TIOCSWINSZ`.
@MainActor
final class TerminalPaneCardGeometryTests: XCTestCase {
    /// Records what the PTY was told, and what the terminal wrote back.
    private final class RecordingSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((TerminalChildExit) -> Void)?

        private(set) var reportedSizes: [TerminalSize] = []
        private(set) var writes: [String] = []

        func start(workingDirectory: String) {}
        func write(_ text: String) { writes.append(text) }
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {
            reportedSizes.append(TerminalSize(columns: columns, rows: rows))
        }

        func stop() {}
    }

    func testPaneAppearanceSettingsApplyBorderAndInactiveDimming() {
        let pane = TerminalPaneView(frame: NSRect(origin: .zero, size: Fixture.paneSizes[0]), session: RecordingSession())
        var settings = AppSettings.default
        settings.terminal.paneBorderStyle = TerminalPaneBorderStyle.active.rawValue
        settings.terminal.inactivePaneDimmingEnabled = true

        pane.applyPaneAppearanceSettings(settings)

        XCTAssertEqual(pane.layer?.borderWidth, DesignTokens.Component.hairlinePX)
        XCTAssertLessThan(pane.alphaValue, 1)
        pane.setChromeActive(true)
        XCTAssertEqual(pane.alphaValue, 1)
    }

    private enum Fixture {
        /// Pane rects that stand in for the split configurations a user hits: a
        /// full-width single pane, one half of a side-by-side split, one
        /// quarter of a four-way split, and a deliberately cramped pane.
        ///
        /// The widths are the halves an 8pt gutter actually produces
        /// (1280 = 636 + 8 + 636), so the numbers are the ones the split view
        /// hands out rather than round ones.
        static let paneSizes: [NSSize] = [
            NSSize(width: 1280, height: 800),
            NSSize(width: 636, height: 800),
            NSSize(width: 636, height: 396),
            NSSize(width: 360, height: 240),
        ]

        /// A pane shows no header when it is the only one in its tab, and a
        /// 28pt header once it is in a split. The header owns the card's top
        /// corners in the second case, which changes which cells are nearest
        /// the arc.
        static let headerHeightsPX: [CGFloat] = [0, 28]

        /// A glyph that fills its cell in the default terminal font, so a row
        /// of them is a real full-width row rather than a run of spaces.
        static let fullWidthRowGlyph = "X"
    }

    /// XTWINOPS report parameters Kurotty answers with, mirrored here rather
    /// than reached into: the test is asserting on the wire format a TUI sees.
    private enum WindowReport {
        static let textAreaSizePixelsQuery = "\u{1b}[14t"
        static let cellSizePixelsQuery = "\u{1b}[16t"
        static let textAreaSizeCharactersQuery = "\u{1b}[18t"
        static let textAreaSizePixelsResponse = 4
        static let cellSizePixelsResponse = 6
        static let textAreaSizeCharactersResponse = 8
    }

    private struct CardGeometry {
        let cardRect: NSRect
        let surfaceFrame: NSRect
    }

    // MARK: - Fixtures

    /// A pane card of `size` with a header of `headerHeight`, and the terminal
    /// surface frame the pane gives the rest of the card.
    ///
    /// Mirrors `TerminalPaneView.configureLayout`: the surface is pinned to the
    /// card's leading, trailing, and bottom edges, and to the header's bottom.
    private func geometry(size: NSSize, headerHeight: CGFloat) -> CardGeometry {
        let cardRect = NSRect(origin: .zero, size: size)
        return CardGeometry(
            cardRect: cardRect,
            surfaceFrame: NSRect(
                x: cardRect.minX,
                y: cardRect.minY,
                width: cardRect.width,
                height: cardRect.height - headerHeight
            )
        )
    }

    private func makeSurface(frame: NSRect) -> (TerminalSurfaceView, RecordingSession) {
        let session = RecordingSession()
        let surface = TerminalSurfaceView(frame: frame, session: session)
        surface.layoutSubtreeIfNeeded()
        return (surface, session)
    }

    private var gridInset: NSEdgeInsets {
        NSEdgeInsets(
            top: DesignTokens.Space.terminalTopPX,
            left: DesignTokens.Space.terminalLeftPX,
            bottom: DesignTokens.Space.terminalBottomPX,
            right: DesignTokens.Space.terminalRightPX
        )
    }

    // MARK: - Reading the terminal's own answers

    /// Sends an XTWINOPS query and returns the two values from the reply.
    ///
    /// Going through the PTY rather than through a metrics accessor is the
    /// point: this is the geometry a TUI is told, so if it disagrees with the
    /// card the disagreement is a real bug and not a test artifact.
    private func windowReport(
        _ query: String,
        expecting parameter: Int,
        from surface: TerminalSurfaceView,
        session: RecordingSession
    ) throws -> (height: Int, width: Int) {
        let writeCountBeforeQuery = session.writes.count
        surface.consumeTmuxRestoreOutputForTesting(Data(query.utf8))
        let reply = try XCTUnwrap(
            session.writes.dropFirst(writeCountBeforeQuery).last,
            "the terminal did not answer \(query.debugDescription)"
        )
        let expectedPrefix = "\u{1b}[\(parameter);"
        let body = try XCTUnwrap(
            reply.hasPrefix(expectedPrefix) && reply.hasSuffix("t")
                ? String(reply.dropFirst(expectedPrefix.count).dropLast())
                : nil,
            "unexpected reply \(reply.debugDescription) for \(query.debugDescription)"
        )
        let values = body.split(separator: ";").compactMap { Int($0) }
        guard values.count == 2 else {
            XCTFail("expected two values in \(reply.debugDescription)")
            return (0, 0)
        }
        return (values[0], values[1])
    }

    private func reportedGrid(
        from surface: TerminalSurfaceView,
        session: RecordingSession
    ) throws -> TerminalSize {
        let report = try windowReport(
            WindowReport.textAreaSizeCharactersQuery,
            expecting: WindowReport.textAreaSizeCharactersResponse,
            from: surface,
            session: session
        )
        return TerminalSize(columns: report.width, rows: report.height)
    }

    private func reportedTextArea(
        from surface: TerminalSurfaceView,
        session: RecordingSession
    ) throws -> NSSize {
        let report = try windowReport(
            WindowReport.textAreaSizePixelsQuery,
            expecting: WindowReport.textAreaSizePixelsResponse,
            from: surface,
            session: session
        )
        return NSSize(width: CGFloat(report.width), height: CGFloat(report.height))
    }

    private func reportedCellSize(
        from surface: TerminalSurfaceView,
        session: RecordingSession
    ) throws -> NSSize {
        let report = try windowReport(
            WindowReport.cellSizePixelsQuery,
            expecting: WindowReport.cellSizePixelsResponse,
            from: surface,
            session: session
        )
        return NSSize(width: CGFloat(report.width), height: CGFloat(report.height))
    }

    // MARK: - The inset reaches the PTY

    /// One grid, three consumers. What `TIOCSWINSZ` carried, what the terminal
    /// answers `CSI 18 t` with, and what the renderer is drawing must be the
    /// same numbers; a pane whose PTY lags its own geometry is a shell wrapping
    /// against columns that are not there.
    func testPTYSizeMatchesTheGridTheTerminalReports() throws {
        for size in Fixture.paneSizes {
            let card = geometry(size: size, headerHeight: 0)
            let (surface, session) = makeSurface(frame: card.surfaceFrame)

            let ptySize = try XCTUnwrap(
                session.reportedSizes.last,
                "\(size) never reached the PTY"
            )
            XCTAssertEqual(
                ptySize,
                try reportedGrid(from: surface, session: session),
                "PTY and XTWINOPS disagree at \(size)"
            )
            XCTAssertEqual(ptySize, surface.currentTerminalSize, "PTY lags the grid at \(size)")
        }
    }

    /// The failure this exists to catch: the grid is inset to clear the card's
    /// corners but `TIOCSWINSZ` still carries the un-inset count, so the shell
    /// believes it owns a column and a row that are behind the arc.
    ///
    /// A fixed pane size cannot prove this — a 16pt inset is smaller than a cell
    /// on both axes, so most sizes lose nothing and an un-inset grid would agree
    /// with an inset one by luck. So the pane is built at the boundary instead:
    /// half a point under a whole number of cells plus the inset, which is
    /// exactly where the two counts must differ. If the inset is not subtracted
    /// before the division, the PTY comes back one column and one row too big.
    func testPTYLosesTheRowAndColumnTheInsetTakes() throws {
        let inset = gridInset
        let cell = try measuredCellSize()
        let cellsAcross = 20
        let cellsDown = 10
        let boundaryOvershootPX: CGFloat = 0.5

        let boundarySize = NSSize(
            width: inset.left + inset.right + cell.width * CGFloat(cellsAcross) - boundaryOvershootPX,
            height: inset.top + inset.bottom + cell.height * CGFloat(cellsDown) - boundaryOvershootPX
        )
        let (_, session) = makeSurface(frame: NSRect(origin: .zero, size: boundarySize))
        let ptySize = try XCTUnwrap(session.reportedSizes.last, "\(boundarySize) never reached the PTY")

        XCTAssertEqual(
            ptySize.columns,
            cellsAcross - 1,
            "the horizontal inset never reached the PTY: it reported \(ptySize.columns) columns "
                + "for a pane that holds \(cellsAcross - 1) inside the card"
        )
        XCTAssertEqual(
            ptySize.rows,
            cellsDown - 1,
            "the vertical inset never reached the PTY: it reported \(ptySize.rows) rows "
                + "for a pane that holds \(cellsDown - 1) inside the card"
        )
        // The counts an inset-blind implementation would have produced, so the
        // assertions above are known to be discriminating rather than trivially
        // true at this size.
        XCTAssertGreaterThan(Int(boundarySize.width / cell.width), ptySize.columns)
        XCTAssertGreaterThan(Int(boundarySize.height / cell.height), ptySize.rows)
    }

    /// Cell size to sub-pixel precision, recovered from the terminal's own
    /// reports rather than re-measured from the font.
    ///
    /// `CSI 16 t` rounds to whole pixels, which is too coarse to build a
    /// boundary out of. `CSI 14 t` reports the text area, so dividing it by the
    /// grid recovers the cell to within half a pixel spread over every cell.
    private func measuredCellSize() throws -> NSSize {
        let probeFrame = NSRect(origin: .zero, size: Fixture.paneSizes[0])
        let (surface, session) = makeSurface(frame: probeFrame)
        let grid = try reportedGrid(from: surface, session: session)
        let textArea = try reportedTextArea(from: surface, session: session)
        XCTAssertGreaterThan(grid.columns, 0)
        XCTAssertGreaterThan(grid.rows, 0)
        return NSSize(
            width: textArea.width / CGFloat(grid.columns),
            height: textArea.height / CGFloat(grid.rows)
        )
    }

    /// The reported grid has to fit inside the inset box, and to fill it: a grid
    /// that overflows is a shell drawing under the arc, and a grid with a whole
    /// spare cell of slack is usable area thrown away for nothing.
    func testReportedTextAreaFitsInsideTheInsetBoxWithLessThanOneCellToSpare() throws {
        let inset = gridInset
        for size in Fixture.paneSizes {
            let card = geometry(size: size, headerHeight: 0)
            let (surface, session) = makeSurface(frame: card.surfaceFrame)
            let textArea = try reportedTextArea(from: surface, session: session)
            let cell = try reportedCellSize(from: surface, session: session)

            let availableWidth = card.surfaceFrame.width - inset.left - inset.right
            let availableHeight = card.surfaceFrame.height - inset.top - inset.bottom
            XCTAssertLessThanOrEqual(textArea.width, availableWidth, "text area overflows at \(size)")
            XCTAssertLessThanOrEqual(textArea.height, availableHeight, "text area overflows at \(size)")
            XCTAssertLessThan(
                availableWidth - textArea.width,
                cell.width,
                "a whole column of usable width is unused at \(size)"
            )
            XCTAssertLessThan(
                availableHeight - textArea.height,
                cell.height,
                "a whole row of usable height is unused at \(size)"
            )
        }
    }

    // MARK: - The corners stay off the cells

    /// Every cell that touches a card corner has to sit inside the arc.
    ///
    /// Checked as containment of the real cell rectangles in the real rounded
    /// path rather than as arithmetic on the tokens, because the arithmetic is
    /// what would be wrong if the radius or an inset moved.
    func testCornerCellsStayInsideTheRoundedCardAtEveryPaneSize() throws {
        let radius = DesignTokens.TerminalPaneCard.cornerRadiusPX
        for size in Fixture.paneSizes {
            for headerHeight in Fixture.headerHeightsPX {
                let card = geometry(size: size, headerHeight: headerHeight)
                let (surface, session) = makeSurface(frame: card.surfaceFrame)
                let grid = try reportedGrid(from: surface, session: session)
                let cell = try reportedCellSize(from: surface, session: session)
                let cardPath = CGPath(
                    roundedRect: card.cardRect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                )

                for row in [0, grid.rows - 1] {
                    for column in [0, grid.columns - 1] {
                        let cellRect = TerminalSurfaceView.cursorCellRectInViewCoordinates(
                            boundsHeight: card.surfaceFrame.height,
                            padding: gridInset,
                            cursorRow: row,
                            cursorColumn: column,
                            cellSize: cell,
                            columns: grid.columns,
                            rows: grid.rows
                        )
                        assertCellIsInside(
                            cardPath,
                            cellRect: cellRect,
                            surfaceFrame: card.surfaceFrame,
                            label: "cell (row \(row), column \(column)) of \(size) header \(headerHeight)"
                        )
                    }
                }
            }
        }
    }

    /// Every corner of `cellRect`, expressed in card coordinates, lies inside
    /// `path`.
    ///
    /// The surface sits at the card's bottom-left with only its height reduced
    /// by the header, so a surface-local point is already a card-local point.
    private func assertCellIsInside(
        _ path: CGPath,
        cellRect: NSRect,
        surfaceFrame: NSRect,
        label: String
    ) {
        let corners = [
            CGPoint(x: cellRect.minX, y: cellRect.minY),
            CGPoint(x: cellRect.maxX, y: cellRect.minY),
            CGPoint(x: cellRect.minX, y: cellRect.maxY),
            CGPoint(x: cellRect.maxX, y: cellRect.maxY),
        ]
        for corner in corners {
            let cardPoint = CGPoint(x: surfaceFrame.minX + corner.x, y: surfaceFrame.minY + corner.y)
            XCTAssertTrue(
                path.contains(cardPoint),
                "\(label): corner \(cardPoint) falls outside the card's rounded edge"
            )
        }
    }

    // MARK: - A full-width row still reaches the last column

    /// A TUI that paints to the last column must keep that column: it has to
    /// land on the screen, stay on one row, and draw inside the card.
    ///
    /// This is the check the corner arithmetic cannot make on its own. A grid
    /// that is one column too wide for the card still passes every inequality
    /// above if the inset and the radius were both adjusted together; only
    /// filling the row shows whether the last cell is actually reachable.
    func testFullWidthRowFillsTheLastColumnInsideTheCard() throws {
        let radius = DesignTokens.TerminalPaneCard.cornerRadiusPX
        let inset = gridInset
        for size in Fixture.paneSizes {
            let card = geometry(size: size, headerHeight: 0)
            let (surface, session) = makeSurface(frame: card.surfaceFrame)
            let grid = try reportedGrid(from: surface, session: session)
            let cell = try reportedCellSize(from: surface, session: session)

            let fullRow = String(repeating: Fixture.fullWidthRowGlyph, count: grid.columns)
            surface.consumeTmuxRestoreOutputForTesting(Data(fullRow.utf8))

            let visibleLines = surface.tmuxRestoreStateForTesting.visibleLines
            let firstLine = try XCTUnwrap(visibleLines.first, "no rendered row at \(size)")
            XCTAssertEqual(
                firstLine.filter { String($0) == Fixture.fullWidthRowGlyph }.count,
                grid.columns,
                "a full-width row lost cells at \(size)"
            )
            XCTAssertTrue(
                visibleLines.dropFirst().allSatisfy { line in
                    !line.contains(Fixture.fullWidthRowGlyph)
                },
                "a full-width row wrapped onto a second line at \(size)"
            )

            let lastCell = TerminalSurfaceView.cursorCellRectInViewCoordinates(
                boundsHeight: card.surfaceFrame.height,
                padding: inset,
                cursorRow: 0,
                cursorColumn: grid.columns - 1,
                cellSize: cell,
                columns: grid.columns,
                rows: grid.rows
            )
            XCTAssertLessThanOrEqual(
                lastCell.maxX,
                card.cardRect.maxX - inset.right,
                "the last column runs into the card's right inset at \(size)"
            )
            assertCellIsInside(
                CGPath(roundedRect: card.cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil),
                cellRect: lastCell,
                surfaceFrame: card.surfaceFrame,
                label: "last column of \(size)"
            )
        }
    }

    // MARK: - The token invariant the shape depends on

    /// The grid inset is the only thing keeping the arc off the cells, so every
    /// edge of it has to clear `minimumGridInsetPX`. Raising the radius without
    /// raising the inset fails here rather than in a screenshot.
    func testEveryGridInsetEdgeClearsTheCornerRadiusRequirement() {
        let minimum = DesignTokens.TerminalPaneCard.minimumGridInsetPX
        let edges: [(String, CGFloat)] = [
            ("top", DesignTokens.Space.terminalTopPX),
            ("left", DesignTokens.Space.terminalLeftPX),
            ("bottom", DesignTokens.Space.terminalBottomPX),
            ("right", DesignTokens.Space.terminalRightPX),
        ]
        for (name, value) in edges {
            XCTAssertGreaterThanOrEqual(
                value,
                minimum,
                "\(name) inset \(value) is under the \(minimum) the corner radius needs"
            )
        }
    }

    /// The gutter between two cards has to stay wide enough to grab, because
    /// the divider no longer draws anything the eye can aim at.
    func testGutterStaysWideEnoughToDrag() {
        XCTAssertGreaterThanOrEqual(
            DesignTokens.TerminalPaneCard.gutterPX,
            DesignTokens.Space.x3PX
        )
    }
}
