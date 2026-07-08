@testable import KurottyCore
import XCTest

final class TerminalRenderFrameDiagnosticsTests: XCTestCase {
    func testPreeditRangeKeepsWideHangulInsideRightEdge() {
        let range = TerminalPreeditRenderRange.resolve(
            text: "가",
            anchorColumn: 9,
            columns: 10
        )

        XCTAssertEqual(range?.startColumn, 8)
        XCTAssertEqual(range?.endColumn, 10)
        XCTAssertEqual(range?.sourceCharacterOffset, 0)
    }

    func testPreeditRangeDropsLeadingCharactersOnlyWhenTextExceedsScreenWidth() {
        let range = TerminalPreeditRenderRange.resolve(
            text: "abcdef",
            anchorColumn: 2,
            columns: 4
        )

        XCTAssertEqual(range?.startColumn, 0)
        XCTAssertEqual(range?.endColumn, 4)
        XCTAssertEqual(range?.sourceCharacterOffset, 2)
    }

    func testPreeditRangeMapsSelectedUTF16LocationToCursorColumn() throws {
        let range = try XCTUnwrap(TerminalPreeditRenderRange.resolve(
            text: "안녕",
            anchorColumn: 4,
            columns: 20
        ))

        XCTAssertEqual(range.cursorColumn(in: "안녕", selectedUTF16Location: 0), 4)
        XCTAssertEqual(range.cursorColumn(in: "안녕", selectedUTF16Location: 1), 6)
        XCTAssertEqual(range.cursorColumn(in: "안녕", selectedUTF16Location: 2), 8)
    }

    func testDamageMetadataDistinguishesFullRowAndRectDamage() {
        XCTAssertEqual(
            makeFrame(dirtyRows: [0, 1], dirtyRects: [rowRect(0), rowRect(1)], isFullDamage: true)
                .damageMetadata.kind,
            .fullRedraw
        )
        XCTAssertEqual(
            makeFrame(dirtyRows: [2], dirtyRects: [rowRect(2)], isFullDamage: false)
                .damageMetadata.kind,
            .rowDamage
        )
        XCTAssertEqual(
            makeFrame(dirtyRows: [], dirtyRects: [TerminalFrameRect(x: 3, y: 4, width: 5, height: 6)], isFullDamage: false)
                .damageMetadata.kind,
            .rectDamage
        )
        XCTAssertEqual(
            makeFrame(dirtyRows: [], dirtyRects: [], isFullDamage: false)
                .damageMetadata.kind,
            .none
        )
    }

    func testStableDamagePixelBoundsScaleAndClipMargins() {
        let frame = makeFrame(
            dirtyRows: [],
            dirtyRects: [
                TerminalFrameRect(x: 2.25, y: 3.5, width: 10.25, height: 4.25),
                TerminalFrameRect(x: -1, y: -2, width: 3, height: 3),
            ],
            isFullDamage: false
        )

        let bounds = frame.damageMetadata.stablePixelBounds(
            scale: 2,
            clippingMargin: 0.5,
            clipTo: TerminalFrameSize(width: 30, height: 20)
        )

        XCTAssertEqual(bounds, [
            TerminalFramePixelRect(x: 3, y: 6, width: 23, height: 11),
            TerminalFramePixelRect(x: 0, y: 0, width: 5, height: 3),
        ])
        XCTAssertTrue(frame.damageMetadata.canResolveStablePixelBounds(scale: 2))
    }

    func testStableDamagePixelBoundsRejectsUnstableOrEmptyRects() {
        XCTAssertFalse(
            makeFrame(
                dirtyRows: [],
                dirtyRects: [TerminalFrameRect(x: 0, y: 0, width: 0, height: 4)],
                isFullDamage: false
            )
            .damageMetadata.canResolveStablePixelBounds(scale: 2)
        )
        XCTAssertFalse(
            makeFrame(
                dirtyRows: [],
                dirtyRects: [TerminalFrameRect(x: 0, y: 0, width: 4, height: 4)],
                isFullDamage: false
            )
            .damageMetadata.canResolveStablePixelBounds(scale: 0)
        )
        XCTAssertFalse(
            makeFrame(
                dirtyRows: [],
                dirtyRects: [TerminalFrameRect(x: 100, y: 100, width: 4, height: 4)],
                isFullDamage: false
            )
            .damageMetadata.canResolveStablePixelBounds(
                scale: 2,
                clipTo: TerminalFrameSize(width: 20, height: 20)
            )
        )
    }

    func testStableDamagePixelBoundsDiagnosticsReportFallbackReasons() {
        let emptyReport = makeFrame(
            dirtyRows: [],
            dirtyRects: [],
            isFullDamage: false
        )
        .damageMetadata.stablePixelBoundsReport(scale: 2)

        XCTAssertEqual(emptyReport.pixelBounds, [])
        XCTAssertEqual(emptyReport.stablePixelBoundCount, 0)
        XCTAssertEqual(emptyReport.fallbackReason?.description, "no-dirty-rects")

        let unstableReport = makeFrame(
            dirtyRows: [],
            dirtyRects: [TerminalFrameRect(x: 0, y: 0, width: 0, height: 4)],
            isFullDamage: false
        )
        .damageMetadata.stablePixelBoundsReport(scale: 2)

        XCTAssertEqual(unstableReport.pixelBounds, [])
        XCTAssertEqual(unstableReport.stablePixelBoundCount, 0)
        XCTAssertEqual(unstableReport.fallbackReason?.description, "unstable-dirty-rect")

        let outsideReport = makeFrame(
            dirtyRows: [],
            dirtyRects: [TerminalFrameRect(x: 100, y: 100, width: 4, height: 4)],
            isFullDamage: false
        )
        .damageMetadata.stablePixelBoundsReport(
            scale: 2,
            clipTo: TerminalFrameSize(width: 20, height: 20)
        )

        XCTAssertEqual(outsideReport.pixelBounds, [])
        XCTAssertEqual(outsideReport.stablePixelBoundCount, 0)
        XCTAssertEqual(outsideReport.fallbackReason?.description, "outside-display-bounds")
    }

    func testDamageRedrawPolicyKeepsPartialFallbackExplicitWhenScissorIsDisabled() {
        let policy = makeFrame(
            dirtyRows: [1],
            dirtyRects: [rowRect(1)],
            isFullDamage: false
        )
        .damageMetadata.redrawPolicy(
            scale: 2,
            clipTo: TerminalFrameSize(width: 80, height: 40),
            diagnosticFullRedrawEnabled: false,
            scissorDisabled: true
        )

        XCTAssertEqual(policy.redrawDecision.description, "partial")
        XCTAssertEqual(policy.schedulingPolicy.description, "immediate-partial-redraw")
        XCTAssertEqual(policy.coalescingFallbackReason.description, "scissor-disabled")
        XCTAssertFalse(policy.canCoalesceAtDisplayCadence)
        XCTAssertEqual(policy.stablePixelBounds, [TerminalFramePixelRect(x: 0, y: 40, width: 80, height: 40)])
        XCTAssertEqual(policy.stablePixelBoundCount, 1)
    }

    private func makeFrame(
        dirtyRows: [Int],
        dirtyRects: [TerminalFrameRect],
        isFullDamage: Bool
    ) -> TerminalFrame {
        TerminalFrame(
            cells: [],
            backgrounds: [],
            decorations: [],
            defaultForeground: .zero,
            defaultBackground: .zero,
            dirtyRows: dirtyRows,
            dirtyRects: dirtyRects,
            isFullDamage: isFullDamage,
            cursorColumn: 0,
            cursorRow: 0,
            cursorBlinkOn: true,
            markedTextColumn: 0,
            markedText: "",
            markedTextSelectedRange: .none,
            columns: 4,
            visibleRows: 4,
            cellSize: TerminalFrameSize(width: 10, height: 20),
            padding: .zero
        )
    }

    private func rowRect(_ row: Int) -> TerminalFrameRect {
        TerminalFrameRect(x: 0, y: Double(row * 20), width: 40, height: 20)
    }
}
