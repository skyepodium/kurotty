@testable import KurottyCore
import XCTest

final class TerminalRenderFrameDiagnosticsTests: XCTestCase {
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
