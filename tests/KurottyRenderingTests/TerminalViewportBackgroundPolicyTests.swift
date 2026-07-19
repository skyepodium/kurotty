import XCTest
@testable import KurottyCore

final class TerminalViewportBackgroundPolicyTests: XCTestCase {
    func testFullScreenApplicationBackgroundWinsOverThemeFallback() {
        let fallback = SIMD4<Float>(1, 1, 1, 1)
        let applicationBackground = SIMD4<Float>(0.078, 0.078, 0.078, 1)
        let style = TerminalTextStyle(
            foreground: SIMD4<Float>(0.8, 0.8, 0.8, 1),
            background: applicationBackground
        )
        let rows = Array(
            repeating: Array(repeating: TerminalScreenCell(style: style), count: 8),
            count: 4
        )

        let background = TerminalViewportBackgroundPolicy.background(
            in: rows,
            columns: 8,
            fallback: fallback
        )

        XCTAssertEqual(background, applicationBackground)
    }

    func testInteriorPanelDoesNotChangeViewportEdgeBackground() {
        let fallback = SIMD4<Float>(1, 1, 1, 1)
        let panelBackground = SIMD4<Float>(0.1, 0.1, 0.1, 1)
        let fallbackStyle = TerminalTextStyle(foreground: .zero, background: fallback)
        let panelStyle = TerminalTextStyle(foreground: .zero, background: panelBackground)
        var rows = Array(
            repeating: Array(repeating: TerminalScreenCell(style: fallbackStyle), count: 5),
            count: 5
        )
        for row in 1...3 {
            for column in 1...3 {
                rows[row][column] = TerminalScreenCell(style: panelStyle)
            }
        }

        XCTAssertEqual(
            TerminalViewportBackgroundPolicy.background(in: rows, columns: 5, fallback: fallback),
            fallback
        )
    }

    func testUnstyledBlankCellsUseThemeFallback() {
        let fallback = SIMD4<Float>(1, 1, 1, 1)
        let rows = Array(
            repeating: Array(repeating: TerminalScreenCell(), count: 4),
            count: 3
        )

        XCTAssertEqual(
            TerminalViewportBackgroundPolicy.background(in: rows, columns: 4, fallback: fallback),
            fallback
        )
    }
}
