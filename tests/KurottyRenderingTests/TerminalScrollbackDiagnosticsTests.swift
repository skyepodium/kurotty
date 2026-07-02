import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class TerminalScrollbackDiagnosticsTests: XCTestCase {
    func testSummaryReportsEmptyScrollback() {
        var rows = BoundedScrollbackRows()

        rows.trim(to: 10)
        let summary = TerminalScrollbackDiagnosticsSummary(rows.diagnostics)

        XCTAssertEqual(summary.capacity, 10)
        XCTAssertEqual(summary.retainedRowCount, 0)
        XCTAssertEqual(summary.retainedStorageRowCount, 0)
        XCTAssertEqual(summary.droppedRowCount, 0)
        XCTAssertEqual(summary.compactionCount, 0)
        XCTAssertEqual(summary.pressureLevel, .empty)
        XCTAssertEqual(summary.status, .empty)
    }

    func testSummaryReportsNormalScrollbackWithoutRowContent() {
        var rows = BoundedScrollbackRows()

        rows.append(contentsOf: makeRows(["secret token", "normal output"]), limit: 10)
        let summary = TerminalScrollbackDiagnosticsSummary(rows.diagnostics)

        XCTAssertEqual(summary.capacity, 10)
        XCTAssertEqual(summary.retainedRowCount, 2)
        XCTAssertEqual(summary.retainedStorageRowCount, 2)
        XCTAssertEqual(summary.droppedRowCount, 0)
        XCTAssertEqual(summary.pressureLevel, .low)
        XCTAssertEqual(summary.status, .healthy)
        XCTAssertFalse(summary.description.contains("secret"))
        XCTAssertFalse(summary.description.contains("normal output"))
    }

    func testSummaryReportsNearCapacityPressure() {
        var rows = BoundedScrollbackRows()

        rows.append(contentsOf: makeRows(count: 8), limit: 10)
        let summary = TerminalScrollbackDiagnosticsSummary(rows.diagnostics)

        XCTAssertEqual(summary.capacity, 10)
        XCTAssertEqual(summary.retainedRowCount, 8)
        XCTAssertEqual(summary.droppedRowCount, 0)
        XCTAssertEqual(summary.pressureLevel, .high)
        XCTAssertEqual(summary.status, .nearCapacity)
    }

    func testSummaryReportsOverflowAndDroppedRows() {
        var rows = BoundedScrollbackRows()

        rows.append(contentsOf: makeRows(count: 30), limit: 10)
        let summary = TerminalScrollbackDiagnosticsSummary(rows.diagnostics)

        XCTAssertEqual(summary.capacity, 10)
        XCTAssertEqual(summary.retainedRowCount, 10)
        XCTAssertEqual(summary.retainedStorageRowCount, 30)
        XCTAssertEqual(summary.droppedRowCount, 20)
        XCTAssertEqual(summary.compactionCount, 0)
        XCTAssertEqual(summary.pressureLevel, .saturated)
        XCTAssertEqual(summary.status, .droppingRows)
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
