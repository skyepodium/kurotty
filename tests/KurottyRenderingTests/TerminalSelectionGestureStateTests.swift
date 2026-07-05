import XCTest
@testable import KurottyCore
@testable import KurottyApp

final class TerminalSelectionGestureStateTests: XCTestCase {
    func testWordSelectionBoundsTreatWideCharacterContinuationAsPartOfWord() {
        var row = TerminalSelectionTestRow(columns: 8)
        row.write("안", column: 0, width: 2)
        row.write("녕", column: 2, width: 2)
        row.write("~", column: 4, width: 1)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 2)

        XCTAssertEqual(bounds?.startColumn, 0)
        XCTAssertEqual(bounds?.endColumn, 4)
    }

    func testWordSelectionBoundsResolveClicksOnWideCharacterContinuation() {
        var row = TerminalSelectionTestRow(columns: 8)
        row.write("안", column: 0, width: 2)
        row.write("녕", column: 2, width: 2)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 1)

        XCTAssertEqual(bounds?.startColumn, 0)
        XCTAssertEqual(bounds?.endColumn, 3)
    }

    func testWordSelectionBoundsSnapBlankBetweenWideCharactersToWord() {
        var row = TerminalSelectionTestRow(columns: 8)
        row.write("안", column: 0, width: 2)
        row.write("녕", column: 3, width: 2)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 2)

        XCTAssertEqual(bounds?.startColumn, 0)
        XCTAssertEqual(bounds?.endColumn, 4)
    }

    func testWordSelectionBoundsTreatBlankCellsBetweenCJKLettersAsWordInterior() {
        var row = TerminalSelectionTestRow(columns: 12)
        row.write("안", column: 0, width: 1)
        row.write("녕", column: 2, width: 1)
        row.write("하", column: 4, width: 1)
        row.write("세", column: 6, width: 1)
        row.write("요", column: 8, width: 1)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 6)

        XCTAssertEqual(bounds?.startColumn, 0)
        XCTAssertEqual(bounds?.endColumn, 8)
    }

    func testWordSelectionBoundsStopsAtRealWhitespaceBetweenCJKWords() {
        var row = TerminalSelectionTestRow(columns: 16)
        row.write("무", column: 0, width: 1)
        row.write("엇", column: 2, width: 1)
        row.write("을", column: 4, width: 1)
        row.write("도", column: 8, width: 1)
        row.write("와", column: 10, width: 1)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 2)

        XCTAssertEqual(bounds?.startColumn, 0)
        XCTAssertEqual(bounds?.endColumn, 4)
    }

    func testWordSelectionBoundsTreatBlankBetweenCJKAndPunctuationAsGlyphInterior() {
        var row = TerminalSelectionTestRow(columns: 8)
        row.write("줄", column: 0, width: 1)
        row.write("까", column: 2, width: 1)
        row.write("?", column: 4, width: 1)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 3)

        XCTAssertEqual(bounds?.startColumn, 0)
        XCTAssertEqual(bounds?.endColumn, 4)
    }

    func testWordSelectionBoundsIncludesWideGlyphDisplayEndColumn() {
        var row = TerminalSelectionTestRow(columns: 8)
        row.write("안", column: 0, width: 2)
        row.write("녕", column: 2, width: 2)
        row.write("요", column: 4, width: 2)

        let bounds = TerminalWordSelection.bounds(in: row.cells, clickedColumn: 2)

        XCTAssertEqual(bounds?.highlightEndColumn(in: row.cells), 5)
    }

    func testSelectedTextOmitsWideCharacterContinuationCells() {
        var row = TerminalSelectionTestRow(columns: 8)
        row.write("안", column: 0, width: 2)
        row.write("녕", column: 2, width: 2)
        row.write("~", column: 4, width: 1)

        let text = TerminalSelectionText.line(from: row.cells[0...4])

        XCTAssertEqual(text, "안녕~")
    }

    func testSelectedTextOmitsSyntheticBlankCellsBetweenCJKLetters() {
        var row = TerminalSelectionTestRow(columns: 12)
        row.write("안", column: 0, width: 1)
        row.write("녕", column: 2, width: 1)
        row.write("하", column: 4, width: 1)
        row.write("세", column: 6, width: 1)
        row.write("요", column: 8, width: 1)

        let text = TerminalSelectionText.line(from: row.cells[0...8])

        XCTAssertEqual(text, "안녕하세요")
    }

    func testSingleCellSelectionRangeIsNotDiscarded() {
        let position = TerminalSelectionPosition(row: 2, column: 5)
        let range = TerminalSelectionRangeModel.normalized(anchor: position, focus: position)

        XCTAssertEqual(range?.start, position)
        XCTAssertEqual(range?.end, position)
    }

    func testWordSelectionIgnoresPointerUpAtClickedCell() {
        let selectedWordEndColumn = 8
        let clickedColumn = 2
        var focusColumn = selectedWordEndColumn
        var gestureState = TerminalSelectionGestureState()

        gestureState.selectWord()
        if gestureState.shouldUpdateFocusOnPointerUp() {
            focusColumn = clickedColumn
        }

        XCTAssertEqual(focusColumn, selectedWordEndColumn)
    }

    func testWordSelectionIgnoresIncidentalPointerDragAtClickedCell() {
        let selectedWordEndColumn = 8
        let clickedColumn = 2
        var focusColumn = selectedWordEndColumn
        var gestureState = TerminalSelectionGestureState()

        gestureState.selectWord()
        if gestureState.shouldUpdateFocusOnPointerDrag() {
            focusColumn = clickedColumn
        }

        XCTAssertEqual(focusColumn, selectedWordEndColumn)
    }

    func testCharacterSelectionPointerUpCanUpdateFocus() {
        let draggedColumn = 7
        var focusColumn = 1
        var gestureState = TerminalSelectionGestureState()

        gestureState.beginCharacterSelection()
        if gestureState.shouldUpdateFocusOnPointerDrag() {
            focusColumn = draggedColumn
        }

        XCTAssertEqual(focusColumn, draggedColumn)
    }
}

private struct TerminalSelectionTestRow {
    var cells: [TerminalWordSelection.Cell]

    init(columns: Int) {
        cells = Array(repeating: TerminalWordSelection.Cell(character: " ", isContinuation: false), count: columns)
    }

    mutating func write(_ character: Character, column: Int, width: Int) {
        cells[column] = TerminalWordSelection.Cell(character: character, isContinuation: false)
        if width == 2 {
            cells[column + 1] = TerminalWordSelection.Cell(character: " ", isContinuation: true)
        }
    }
}
