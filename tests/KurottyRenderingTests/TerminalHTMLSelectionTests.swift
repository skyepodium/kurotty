import AppKit
import KurottyCore
import WebKit
import XCTest
@testable import KurottyApp

/// The selection contract for the HTML renderer.
///
/// Two halves. The input boundary — no event reaches the web view, so the
/// surface keeps every gesture and `NSTextInputContext` keeps marked text — and
/// the projection, which has to keep the surface's one selection visible after
/// runs are coalesced.
final class TerminalHTMLSelectionTests: XCTestCase {
    private enum Fixture {
        static let rendererFrame = NSRect(x: 0, y: 0, width: 400, height: 200)
        static let pointInsideRenderer = NSPoint(x: 40, y: 40)
        static let fontSizePT: CGFloat = 12
        static let cellWidthPX: Double = 8
        static let cellHeightPX: Double = 16
        static let columnCOUNT = 8
        static let rowCOUNT = 1
        static let selectedStartColumn = 2
        static let selectedEndColumn = 4
        static let text = "abcdefgh"
        static let foreground = SIMD4<Float>(0.8, 0.8, 0.8, 1)
        static let background = SIMD4<Float>(0, 0, 0, 1)
    }

    @MainActor
    private func makeRenderer() -> TerminalHTMLView {
        TerminalHTMLView(
            font: NSFont.monospacedSystemFont(ofSize: Fixture.fontSizePT, weight: .regular),
            backgroundColor: Fixture.background,
            cursorColor: Fixture.foreground
        )
    }

    // MARK: - The input boundary

    @MainActor
    func testWebViewRefusesEveryRouteThatCouldGiveItTheKeyboard() {
        let webView = TerminalHTMLWebView(frame: Fixture.rendererFrame, configuration: WKWebViewConfiguration())

        // Hit testing is the pointer's route; first responder and the key-view
        // loop are the two that never consult it. Marked text follows the first
        // responder, so all three have to refuse.
        XCTAssertNil(webView.hitTest(Fixture.pointInsideRenderer))
        XCTAssertFalse(webView.acceptsFirstResponder)
        XCTAssertFalse(webView.canBecomeKeyView)
    }

    @MainActor
    func testWebViewClaimsNoDropsSoAFileStillLandsOnTheCommandLine() {
        let webView = TerminalHTMLWebView(frame: Fixture.rendererFrame, configuration: WKWebViewConfiguration())

        // Dragging is a fourth route, and the three above do not cover it: a
        // drag destination is found by its registration, not by hit testing or
        // by focus. A stock web view registers seventeen types because dropping
        // a file onto a page is something pages do, and sitting over the surface
        // it took every drop the terminal used to turn into a path.
        XCTAssertTrue(
            webView.registeredDraggedTypes.isEmpty,
            "the web view claimed \(webView.registeredDraggedTypes.count) dragged types"
        )

        // The comparison is the point: this is a property of the subclass, not
        // of web views, so the test fails if the override is ever removed.
        let stock = WKWebView(frame: Fixture.rendererFrame, configuration: WKWebViewConfiguration())
        XCTAssertFalse(stock.registeredDraggedTypes.isEmpty)
    }

    @MainActor
    func testRendererContainerStaysTransparentSoTheSurfaceReceivesTheGesture() {
        let renderer = makeRenderer()
        renderer.frame = Fixture.rendererFrame

        // A selection drag is only reachable because this returns nil: the
        // superview's hit test walks past the renderer and answers with
        // TerminalSurfaceView, which owns the selection.
        XCTAssertNil(renderer.hitTest(Fixture.pointInsideRenderer))
        XCTAssertFalse(renderer.acceptsFirstResponder)
        XCTAssertFalse(renderer.canBecomeKeyView)
    }

    @MainActor
    func testDocumentCannotHoldASelectionOfItsOwn() {
        let document = makeStylesheet()

        // Two selections over the same pixels would disagree. The app's is the
        // one that copies, so the page must not have one.
        XCTAssertTrue(document.contains("user-select: none"))
        XCTAssertTrue(document.contains("-webkit-user-select: none"))
    }

    /// The page as the renderer would load it. No web view and no renderer:
    /// the stylesheet is a description, so a rule in it can be checked as one.
    private func makeStylesheet() -> String {
        TerminalHTMLStylesheet.document(
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            backgroundColor: SIMD4<Float>(0, 0, 0, 1),
            cursorColor: SIMD4<Float>(1, 1, 1, 1),
            cellSize: TerminalFrameSize(width: 8, height: 16),
            padding: TerminalFramePoint(x: 8, y: 8)
        )
    }

    // MARK: - What a screen reader hears

    /// The grid is a wall of pixels to VoiceOver on the atlas path —
    /// `NSAccessibility` appears nowhere in this app — and a document costs
    /// four strings to fix that. This is the only capability in the branch that
    /// the other renderer cannot be given cheaply at all.
    @MainActor
    func testTheScreenIsALiveRegionAReaderCanFollow() {
        let document = makeStylesheet()

        XCTAssertTrue(document.contains("role=\"\(TerminalHTMLDocument.Role.screen)\""))
        XCTAssertTrue(document.contains("aria-live=\"\(TerminalHTMLDocument.Role.liveness)\""))
        XCTAssertTrue(document.contains("aria-label=\"\(TerminalHTMLDocument.Role.label)\""))

        // Assertive would interrupt the reader mid-sentence for every line of a
        // build, which makes a terminal unusable rather than accessible.
        XCTAssertFalse(document.contains("aria-live=\"assertive\""))
    }

    /// The cursor is a painted box with no text in it. Announced, it would
    /// interrupt every row with nothing — its position is already carried by
    /// the text a reader is moving through.
    @MainActor
    func testTheCursorIsNotAnnounced() {
        XCTAssertTrue(makeStylesheet().contains("id=\"cursor\" aria-hidden=\"true\""))
    }

    // MARK: - Where the pointer thinks the grid is

    @MainActor
    func testDocumentPlacesTheGridAtTheFramesPaddingRatherThanTheOrigin() {
        let document = makeStylesheet()

        // `TerminalSurfaceView.visibleCellPosition(for:)` subtracts the padding
        // it puts in the frame before dividing by the cell size. A document that
        // starts row 0 at the page origin therefore draws every glyph a padding
        // away from the cell the pointer resolves to, and a selection drag
        // covers text the user did not point at. The origin has to be a variable
        // the frame drives, and the rows and the cursor have to share it.
        XCTAssertTrue(document.contains("#\(TerminalHTMLDocument.Markup.gridID)"))
        XCTAssertTrue(document.contains("left: var(\(TerminalHTMLDocument.Variable.paddingX))"))
        XCTAssertTrue(document.contains("top: var(\(TerminalHTMLDocument.Variable.paddingY))"))

        let gridElement = "<div id=\"\(TerminalHTMLDocument.Markup.gridID)\">"
        guard let gridStart = document.range(of: gridElement) else {
            return XCTFail("the document must have a grid box")
        }
        let inside = document[gridStart.upperBound...]
        XCTAssertTrue(inside.contains("id=\"screen\""), "rows must sit inside the offset grid box")
        XCTAssertTrue(inside.contains("id=\"cursor\""), "the cursor must share the grid's origin")
    }

    @MainActor
    func testEveryFrameCarriesThePaddingIntoTheDocument() {
        // The stylesheet only seeds the variables; a resize or a font change
        // republishes them. Both names have to travel with the metrics update
        // or the grid's origin freezes at whatever the first document said.
        //
        // The padding rides with the cell box rather than with every frame:
        // both change on a resize or a font change and stay put in between, so
        // they share one message and the per-frame message stays about rows.
        let script = TerminalHTMLView.metricsScriptForTesting

        XCTAssertTrue(script.contains(TerminalHTMLDocument.Variable.paddingX))
        XCTAssertTrue(script.contains(TerminalHTMLDocument.Variable.paddingY))
        XCTAssertTrue(script.contains("paddingX"))
        XCTAssertTrue(script.contains("paddingY"))
    }

    // MARK: - The projection

    /// A frame shaped the way `TerminalSurfaceView.updateRendererFrame` shapes
    /// one: selected cells carry the selection colours on the cell itself and on
    /// a background entry, and the renderer is never told which cells they were.
    private func makeSelectedFrame() -> TerminalFrame {
        var cells: [TerminalCell] = []
        var backgrounds: [TerminalBackground] = []

        for (column, character) in Fixture.text.enumerated() {
            let isSelected = (Fixture.selectedStartColumn...Fixture.selectedEndColumn).contains(column)
            let foreground = isSelected ? TerminalSelectionStyle.foregroundColor : Fixture.foreground
            let background = isSelected ? TerminalSelectionStyle.backgroundColor : Fixture.background
            if isSelected {
                backgrounds.append(TerminalBackground(column: column, row: 0, color: background))
            }
            cells.append(TerminalCell(
                character: character,
                column: column,
                row: 0,
                foreground: foreground,
                background: background
            ))
        }

        return TerminalFrame(
            cells: cells,
            backgrounds: backgrounds,
            decorations: [],
            defaultForeground: Fixture.foreground,
            defaultBackground: Fixture.background,
            dirtyRows: [],
            dirtyRects: [],
            isFullDamage: true,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: Fixture.columnCOUNT,
            visibleRows: Fixture.rowCOUNT,
            cellSize: TerminalFrameSize(width: Fixture.cellWidthPX, height: Fixture.cellHeightPX),
            padding: .zero
        )
    }

    func testSelectedCellsBecomeTheirOwnRunWithTheSelectionColours() {
        let runs = TerminalHTMLDocument.runs(row: 0, frame: makeSelectedFrame())

        // Coalescing merges cells that are indistinguishable on screen. Selected
        // cells are distinguishable, so they must survive as exactly one run of
        // their own: before, selected, after.
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[1].text, "cde")
        XCTAssertEqual(runs[1].background, TerminalSelectionStyle.backgroundColor)
        XCTAssertEqual(runs[1].foreground, TerminalSelectionStyle.foregroundColor)
        XCTAssertEqual(runs[0].background, Fixture.background)
        XCTAssertEqual(runs[2].background, Fixture.background)
    }

    func testSelectionHighlightReachesTheRowMarkup() {
        let markup = TerminalHTMLDocument.rowContents(0, frame: makeSelectedFrame())
        let selectionBackground = TerminalHTMLDocument.css(TerminalSelectionStyle.backgroundColor)

        XCTAssertTrue(markup.contains("background:\(selectionBackground)"))
        XCTAssertTrue(markup.contains(">cde<"))
    }

    func testAnUnselectedRowCarriesNoSelectionColour() {
        var frame = makeSelectedFrame()
        frame = TerminalFrame(
            cells: frame.cells.map {
                TerminalCell(
                    character: $0.character,
                    column: $0.column,
                    row: $0.row,
                    foreground: Fixture.foreground,
                    background: Fixture.background
                )
            },
            backgrounds: [],
            decorations: [],
            defaultForeground: frame.defaultForeground,
            defaultBackground: frame.defaultBackground,
            dirtyRows: [],
            dirtyRects: [],
            isFullDamage: true,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: frame.columns,
            visibleRows: frame.visibleRows,
            cellSize: frame.cellSize,
            padding: frame.padding
        )

        let markup = TerminalHTMLDocument.rowContents(0, frame: frame)
        let selectionBackground = TerminalHTMLDocument.css(TerminalSelectionStyle.backgroundColor)

        XCTAssertFalse(markup.contains(selectionBackground))
    }
}
