import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class BoundedScrollbackRowsTests: XCTestCase {
    func testDiagnosticsAfterAppendBeyondLimit() {
        var rows = BoundedScrollbackRows()

        let visibleAppendCount = rows.append(contentsOf: makeRows(count: 5), limit: 3)

        XCTAssertEqual(visibleAppendCount, 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.diagnostics, .init(
            limit: 3,
            visibleRowCount: 3,
            retainedStorageRowCount: 5,
            droppedRowCount: 2,
            compactionCount: 0,
            pressureLevel: .saturated
        ))
        XCTAssertEqual(rows.row(at: 0)?.first?.character, " ")
    }

    func testDiagnosticsTrackSegmentedStorageAfterDrops() {
        var rows = BoundedScrollbackRows()

        rows.append(contentsOf: makeRows(count: 8), limit: 10)
        XCTAssertTrue(rows.trim(to: 4))

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.diagnostics.limit, 4)
        XCTAssertEqual(rows.diagnostics.visibleRowCount, 4)
        XCTAssertEqual(rows.diagnostics.retainedStorageRowCount, 8)
        XCTAssertEqual(rows.diagnostics.droppedRowCount, 4)
        XCTAssertEqual(rows.diagnostics.compactionCount, 0)
        XCTAssertEqual(rows.diagnostics.pressureLevel, .saturated)
    }

    func testZeroLimitDropsAllRowsAndReportsEmptyPressure() {
        var rows = BoundedScrollbackRows()

        let visibleAppendCount = rows.append(contentsOf: makeRows(count: 3), limit: 0)

        XCTAssertEqual(visibleAppendCount, 0)
        XCTAssertEqual(rows.count, 0)
        XCTAssertNil(rows.row(at: 0))
        XCTAssertEqual(rows.diagnostics, .init(
            limit: 0,
            visibleRowCount: 0,
            retainedStorageRowCount: 0,
            droppedRowCount: 3,
            compactionCount: 1,
            pressureLevel: .empty
        ))
    }

    func testDiagnosticsDoNotExposeRawRowText() {
        var rows = BoundedScrollbackRows()

        rows.append(contentsOf: [[
            TerminalScreenCell(character: "s"),
            TerminalScreenCell(character: "e"),
            TerminalScreenCell(character: "c"),
            TerminalScreenCell(character: "r"),
            TerminalScreenCell(character: "e"),
            TerminalScreenCell(character: "t"),
        ]], limit: 10)

        XCTAssertFalse(String(describing: rows.diagnostics).contains("secret"))
    }

    func testRemappingStylesAndColorsDoesNotChangeDiagnostics() {
        let previousDefaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.1, 0.2, 0.3, 1),
            background: SIMD4<Float>(0.0, 0.0, 0.0, 1)
        )
        let nextDefaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.8, 0.7, 0.6, 1),
            background: SIMD4<Float>(0.1, 0.1, 0.1, 1)
        )
        let explicitStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.4, 0.5, 0.6, 1),
            background: SIMD4<Float>(0.2, 0.2, 0.2, 1),
            bold: true
        )
        var rows = BoundedScrollbackRows()
        rows.append(contentsOf: [
            [TerminalScreenCell(style: previousDefaultStyle)],
            [TerminalScreenCell(style: explicitStyle)],
        ], limit: 4)
        let beforeDiagnostics = rows.diagnostics

        rows.remapStyle(from: previousDefaultStyle, to: nextDefaultStyle)
        let colorMap = TerminalStyleColorMap(
            previousDefaultStyle: nextDefaultStyle,
            nextDefaultStyle: TerminalTextStyle(
                foreground: SIMD4<Float>(0.9, 0.9, 0.9, 1),
                background: SIMD4<Float>(0.0, 0.0, 0.0, 1)
            ),
            previousAnsiColors: [explicitStyle.foreground],
            nextAnsiColors: [SIMD4<Float>(0.7, 0.1, 0.2, 1)]
        )
        rows.remapColors(colorMap)

        XCTAssertEqual(rows.diagnostics, beforeDiagnostics)
        XCTAssertEqual(rows.row(at: 0)?.first?.style.foreground, SIMD4<Float>(0.9, 0.9, 0.9, 1))
        XCTAssertEqual(rows.row(at: 1)?.first?.style.foreground, SIMD4<Float>(0.7, 0.1, 0.2, 1))
    }

    func testRemappingMaterializesBeforeAppendingNewRows() {
        let previousDefaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.1, 0.2, 0.3, 1),
            background: SIMD4<Float>(0.0, 0.0, 0.0, 1)
        )
        let nextDefaultStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.8, 0.7, 0.6, 1),
            background: SIMD4<Float>(0.1, 0.1, 0.1, 1)
        )
        let laterStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(0.2, 0.4, 0.6, 1),
            background: SIMD4<Float>(0.0, 0.0, 0.0, 1)
        )
        var rows = BoundedScrollbackRows()
        rows.append(contentsOf: [[TerminalScreenCell(style: previousDefaultStyle)]], limit: 4)

        rows.remapStyle(from: previousDefaultStyle, to: nextDefaultStyle)
        rows.append(contentsOf: [[TerminalScreenCell(style: laterStyle)]], limit: 4)

        XCTAssertEqual(rows.row(at: 0)?.first?.style, nextDefaultStyle)
        XCTAssertEqual(rows.row(at: 1)?.first?.style, laterStyle)
    }

    func testAppendAtLimitReportsNewVisibleRowsAndDropsOldestRows() {
        var rows = BoundedScrollbackRows()
        rows.append(contentsOf: makeRows(["one", "two", "three"]), limit: 3)

        let visibleAppendCount = rows.append(contentsOf: makeRows(["four"]), limit: 3)

        XCTAssertEqual(visibleAppendCount, 1)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.row(at: 0)?.first?.character, "t")
        XCTAssertEqual(rows.row(at: 2)?.first?.character, "f")
        XCTAssertEqual(rows.diagnostics.droppedRowCount, 1)
        XCTAssertGreaterThanOrEqual(rows.diagnostics.retainedStorageRowCount, rows.diagnostics.visibleRowCount)
    }

    func testPressureLevelThresholds() {
        var rows = BoundedScrollbackRows()

        rows.trim(to: 10)
        XCTAssertEqual(rows.diagnostics.pressureLevel, .empty)

        rows.append(contentsOf: makeRows(count: 4), limit: 10)
        XCTAssertEqual(rows.diagnostics.pressureLevel, .low)

        rows.append(contentsOf: makeRows(count: 1), limit: 10)
        XCTAssertEqual(rows.diagnostics.pressureLevel, .elevated)

        rows.append(contentsOf: makeRows(count: 3), limit: 10)
        XCTAssertEqual(rows.diagnostics.pressureLevel, .high)

        rows.append(contentsOf: makeRows(count: 2), limit: 10)
        XCTAssertEqual(rows.diagnostics.pressureLevel, .saturated)
    }

    private func makeRows(count: Int) -> [[TerminalScreenCell]] {
        (0..<count).map { _ in [TerminalScreenCell()] }
    }

    private func makeRows(_ textRows: [String]) -> [[TerminalScreenCell]] {
        textRows.map { text in
            text.map { character in
                TerminalScreenCell(character: character)
            }
        }
    }
}
