import XCTest
@testable import KurottyCore

final class TerminalCoreScreenTests: XCTestCase {
    func testScreenStoresWideCellsAndClearsContinuations() {
        var screen = TerminalScreen(rows: 1, columns: 4)
        let style = TerminalTextStyle(
            foreground: SIMD4<Float>(0.8, 0.7, 0.6, 1),
            background: SIMD4<Float>(0.1, 0.2, 0.3, 1)
        )

        screen.set(character: "界", row: 0, column: 1, width: 2, style: style)
        XCTAssertEqual(String(screen.cells[0][1].character), "界")
        XCTAssertTrue(screen.cells[0][2].isContinuation)

        screen.set(character: "x", row: 0, column: 2, width: 1, style: .default)

        XCTAssertEqual(String(screen.cells[0][1].character), " ")
        XCTAssertFalse(screen.cells[0][2].isContinuation)
        XCTAssertEqual(String(screen.cells[0][2].character), "x")
    }

    func testDeviceAttributesRemainPortable() {
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters("")), "\u{1b}[?1;2c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters(">0")), "\u{1b}[>0;0;0c")
        XCTAssertNil(TerminalDeviceAttributes.response(for: CsiParameters("?1;2")))
    }
}
