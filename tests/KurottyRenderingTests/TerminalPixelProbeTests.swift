import CoreGraphics
@testable import KurottyApp
import XCTest

final class TerminalPixelProbeTests: XCTestCase {
    func testGlyphExtendingPastNarrowCellReportsCellClipping() {
        let probe = TerminalPixelProbe.make(
            cellRect: CGRect(x: 20, y: 40, width: 16, height: 32),
            glyphRect: CGRect(x: 19, y: 42, width: 19, height: 24),
            dirtyRect: CGRect(x: 20, y: 40, width: 16, height: 32),
            scissorRect: CGRect(x: 20, y: 40, width: 16, height: 32),
            backingScale: 2
        )

        XCTAssertTrue(probe.clippingFlags.glyphExceedsCellBounds)
        XCTAssertTrue(probe.clippingFlags.glyphExceedsDirtyRect)
        XCTAssertTrue(probe.clippingFlags.glyphExceedsScissorRect)
        XCTAssertFalse(probe.clippingFlags.cellExceedsDirtyRect)
        XCTAssertFalse(probe.clippingFlags.cellExceedsScissorRect)
        XCTAssertEqual(probe.reasonCode, .glyphExceedsScissorRect)
        XCTAssertEqual(probe.summary, "glyph-exceeds-scissor-rect")
        XCTAssertEqual(probe.cellRect, CGRect(x: 20, y: 40, width: 16, height: 32))
        XCTAssertEqual(probe.glyphRect, CGRect(x: 19, y: 42, width: 19, height: 24))
        XCTAssertEqual(probe.dirtyRect, CGRect(x: 20, y: 40, width: 16, height: 32))
        XCTAssertEqual(probe.scissorRect, CGRect(x: 20, y: 40, width: 16, height: 32))
        XCTAssertEqual(probe.backingScale, 2)
    }

    func testFractionalBackingPixelEdgesAreReportedWithoutClipping() {
        let probe = TerminalPixelProbe.make(
            cellRect: CGRect(x: 10.25, y: 20, width: 11.5, height: 18),
            glyphRect: CGRect(x: 11, y: 22, width: 8, height: 12),
            dirtyRect: CGRect(x: 10, y: 20, width: 12, height: 18),
            scissorRect: nil,
            backingScale: 2
        )

        XCTAssertTrue(probe.clippingFlags.fractionalPixelEdges)
        XCTAssertFalse(probe.clippingFlags.glyphExceedsCellBounds)
        XCTAssertFalse(probe.clippingFlags.glyphExceedsDirtyRect)
        XCTAssertFalse(probe.clippingFlags.glyphExceedsScissorRect)
        XCTAssertEqual(probe.reasonCode, .fractionalPixelEdges)
        XCTAssertEqual(probe.summary, "fractional-pixel-edges")
    }

    func testContainedPixelProbeReportsCleanReason() {
        let probe = TerminalPixelProbe.make(
            cellRect: CGRect(x: 0, y: 0, width: 20, height: 32),
            glyphRect: CGRect(x: 2, y: 6, width: 12, height: 20),
            dirtyRect: CGRect(x: 0, y: 0, width: 20, height: 32),
            scissorRect: CGRect(x: 0, y: 0, width: 20, height: 32),
            backingScale: 2
        )

        XCTAssertEqual(probe.reasonCode, .contained)
        XCTAssertEqual(probe.summary, "contained")
        XCTAssertFalse(probe.clippingFlags.hasClipping)
    }

    func testProbeWithoutDirtyOrScissorRectDoesNotInventClipping() {
        let probe = TerminalPixelProbe.make(
            cellRect: CGRect(x: 80, y: 0, width: 20, height: 32),
            glyphRect: CGRect(x: 82, y: 6, width: 12, height: 20),
            dirtyRect: nil,
            scissorRect: nil,
            backingScale: 2
        )

        XCTAssertEqual(probe.reasonCode, .contained)
        XCTAssertFalse(probe.clippingFlags.glyphExceedsDirtyRect)
        XCTAssertFalse(probe.clippingFlags.glyphExceedsScissorRect)
        XCTAssertFalse(probe.clippingFlags.hasClipping)
    }
}
