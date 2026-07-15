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

    func testSequentialWideCellsKeepPreviousContinuation() {
        var screen = TerminalScreen(rows: 1, columns: 4)

        screen.set(character: "안", row: 0, column: 0, width: 2)
        screen.set(character: "녕", row: 0, column: 2, width: 2)

        XCTAssertEqual(String(screen.cells[0][0].character), "안")
        XCTAssertTrue(screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(screen.cells[0][2].character), "녕")
        XCTAssertTrue(screen.cells[0][3].isContinuation)
    }

    func testClearLeadCellClearsWideContinuation() {
        var screen = TerminalScreen(rows: 1, columns: 4)

        screen.set(character: "한", row: 0, column: 1, width: 2)
        screen.clear(row: 0, from: 1, through: 1)

        XCTAssertEqual(String(screen.cells[0][1].character), " ")
        XCTAssertFalse(screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(screen.cells[0][2].character), " ")
        XCTAssertFalse(screen.cells[0][2].isContinuation)
    }

    func testClearContinuationCellClearsWideLead() {
        var screen = TerminalScreen(rows: 1, columns: 4)

        screen.set(character: "한", row: 0, column: 1, width: 2)
        screen.clear(row: 0, from: 2, through: 2)

        XCTAssertEqual(String(screen.cells[0][1].character), " ")
        XCTAssertFalse(screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(screen.cells[0][2].character), " ")
        XCTAssertFalse(screen.cells[0][2].isContinuation)
    }

    func testWideOverwriteClearsIntersectingWideCellTail() {
        var screen = TerminalScreen(rows: 1, columns: 5)

        screen.set(character: "한", row: 0, column: 1, width: 2)
        screen.set(character: "界", row: 0, column: 0, width: 2)

        XCTAssertEqual(String(screen.cells[0][0].character), "界")
        XCTAssertTrue(screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(screen.cells[0][2].character), " ")
        XCTAssertFalse(screen.cells[0][2].isContinuation)
    }

    func testInsertCharactersPreservesWideCellWhenInsertedBeforeLeadCell() {
        var screen = TerminalScreen(rows: 1, columns: 5)
        screen.set(character: "한", row: 0, column: 1, width: 2)
        screen.set(character: "x", row: 0, column: 3, width: 1)

        screen.insertCharacters(row: 0, column: 1, count: 1)

        XCTAssertEqual(String(screen.cells[0][2].character), "한")
        XCTAssertTrue(screen.cells[0][3].isContinuation)
        XCTAssertEqual(String(screen.cells[0][4].character), "x")
    }

    func testInsertCharactersClearsWideCellWhenInsertionSplitsIt() {
        var screen = TerminalScreen(rows: 1, columns: 6)
        screen.set(character: "한", row: 0, column: 1, width: 2)
        screen.set(character: "x", row: 0, column: 3, width: 1)

        screen.insertCharacters(row: 0, column: 2, count: 1)

        XCTAssertEqual(String(screen.cells[0][1].character), " ")
        XCTAssertFalse(screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(screen.cells[0][3].character), " ")
        XCTAssertFalse(screen.cells[0][3].isContinuation)
        XCTAssertEqual(String(screen.cells[0][4].character), "x")
    }

    func testDeleteCharactersClearsWideCellWhenDeletionSplitsIt() {
        var screen = TerminalScreen(rows: 1, columns: 5)
        screen.set(character: "한", row: 0, column: 1, width: 2)
        screen.set(character: "x", row: 0, column: 3, width: 1)

        screen.deleteCharacters(row: 0, column: 2, count: 1)

        XCTAssertEqual(String(screen.cells[0][1].character), " ")
        XCTAssertFalse(screen.cells[0][1].isContinuation)
        XCTAssertEqual(String(screen.cells[0][2].character), "x")
    }

    func testResizeClearsWideCellWhenContinuationIsTruncated() {
        var screen = TerminalScreen(rows: 1, columns: 4)
        screen.set(character: "한", row: 0, column: 2, width: 2)

        _ = screen.resize(rows: 1, columns: 3)

        XCTAssertEqual(String(screen.cells[0][2].character), " ")
        XCTAssertFalse(screen.cells[0][2].isContinuation)
    }

    func testWrappedRowMetadataSurvivesResizeAndCharacterEdits() {
        var screen = TerminalScreen(rows: 1, columns: 4)
        screen.set(character: "x", row: 0, column: 3, width: 1)
        screen.markRowWrapped(0)

        screen.insertCharacters(row: 0, column: 1, count: 1)
        XCTAssertTrue(screen.cells[0].last?.wrapsToNextRow == true)

        screen.deleteCharacters(row: 0, column: 1, count: 1)
        XCTAssertTrue(screen.cells[0].last?.wrapsToNextRow == true)

        _ = screen.resize(rows: 1, columns: 6)
        XCTAssertTrue(screen.cells[0].last?.wrapsToNextRow == true)
        XCTAssertFalse(screen.cells[0][3].wrapsToNextRow)
    }

    func testClearingWrappedRowRemovesWrapMetadata() {
        var screen = TerminalScreen(rows: 1, columns: 4)
        screen.markRowWrapped(0)

        screen.clear(row: 0)

        XCTAssertFalse(screen.cells[0].last?.wrapsToNextRow == true)
    }

    func testDeviceAttributesRemainPortable() {
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters("")), "\u{1b}[?1;2c")
        XCTAssertEqual(TerminalDeviceAttributes.response(for: CsiParameters(">0")), "\u{1b}[>0;0;0c")
        XCTAssertNil(TerminalDeviceAttributes.response(for: CsiParameters("?1;2")))
    }
}
