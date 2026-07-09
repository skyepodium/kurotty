import XCTest
@testable import KurottyApp

final class TerminalBlockElementGeometryTests: XCTestCase {
    func testQuadrantBlocksUsePixelAlignedBlockGeometry() {
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "▖"), [
            TerminalBlockElementRect(x: 0, y: 0, width: 0.5, height: 0.5),
        ])
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "▝"), [
            TerminalBlockElementRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ])
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "▚"), [
            TerminalBlockElementRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            TerminalBlockElementRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
        ])
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "▟"), [
            TerminalBlockElementRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 0.5),
        ])
    }

    func testExistingFullAndHalfBlocksStayOnBlockGeometryPath() {
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "█"), [
            TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 1),
        ])
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "▀"), [
            TerminalBlockElementRect(x: 0, y: 0.5, width: 1, height: 0.5),
        ])
        XCTAssertEqual(TerminalBlockElementGeometry.rects(for: "▄"), [
            TerminalBlockElementRect(x: 0, y: 0, width: 1, height: 0.5),
        ])
    }
}
