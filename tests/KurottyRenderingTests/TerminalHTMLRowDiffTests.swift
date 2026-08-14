import XCTest
@testable import KurottyApp

/// The diff is the reason scrolling stopped costing a screen rebuild, so these
/// hold it to the property that makes it worth having: a scroll must produce a
/// plan proportional to the scroll distance, not to the height of the screen.
final class TerminalHTMLRowDiffTests: XCTestCase {
    private enum Fixture {
        static let rows = 24
    }

    private func screen(from first: Int, count: Int = Fixture.rows) -> [String] {
        (0..<count).map { "row \($0 + first)" }
    }

    // MARK: - Scrolling

    func testAScrollOfOneRowReparsesOneRow() {
        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: screen(from: 1))

        XCTAssertFalse(plan.replacesScreen)
        XCTAssertEqual(plan.shift, 1)
        XCTAssertEqual(plan.rows, [Fixture.rows - 1], "only the row that arrived is new")
    }

    func testAScrollOfSeveralRowsReparsesOnlyThoseRows() {
        let distance = 5
        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: screen(from: distance))

        XCTAssertEqual(plan.shift, distance)
        XCTAssertEqual(plan.rows, Array((Fixture.rows - distance)..<Fixture.rows))
    }

    func testScrollingBackMovesRowsTheOtherWay() {
        // A reverse index and a pager scrolling up both push content down.
        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 3), to: screen(from: 0))

        XCTAssertEqual(plan.shift, -3)
        XCTAssertEqual(plan.rows, [0, 1, 2])
    }

    func testAScrollPastTheWholeScreenReplacesIt() {
        // Nothing survived, so there is nothing to move.
        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: screen(from: Fixture.rows))

        XCTAssertTrue(plan.replacesScreen)
    }

    // MARK: - Everything else

    func testAnUnchangedScreenIsNoWorkAtAll() {
        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: screen(from: 0))

        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.replacesScreen)
    }

    func testASingleEditedRowIsASingleRowPatch() {
        var next = screen(from: 0)
        next[7] = "edited"

        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: next)

        XCTAssertEqual(plan.shift, 0)
        XCTAssertEqual(plan.rows, [7])
    }

    func testAFullRepaintReplacesTheScreenInOneParse() {
        // A TUI redraw changes every row and moves none of them. Sending 24
        // patches would be 24 parses and 24 payloads for the same result.
        let next = (0..<Fixture.rows).map { "different \($0)" }

        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: next)

        XCTAssertTrue(plan.replacesScreen)
    }

    func testARepaintThatLeavesTheBottomBlankStillReplacesTheScreen() {
        // The case the first version of this diff got wrong. A TUI redraw
        // rewrites the rows it uses and leaves the rest of the screen alone, so
        // "every row changed" never fires and the plan fell back to patching
        // almost the whole screen one row at a time — measurably slower than
        // the replacement it was avoiding.
        let used = Fixture.rows - 3
        var before = (0..<used).map { "before \($0)" }
        before += Array(repeating: "", count: Fixture.rows - used)
        var after = (0..<used).map { "after \($0)" }
        after += Array(repeating: "", count: Fixture.rows - used)

        XCTAssertTrue(TerminalHTMLRowDiff.plan(from: before, to: after).replacesScreen)
    }

    func testAMinorityOfChangedRowsIsStillPatched() {
        var next = screen(from: 0)
        for row in 0..<(Fixture.rows / 4) {
            next[row] = "edited \(row)"
        }

        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: next)

        XCTAssertFalse(plan.replacesScreen)
        XCTAssertEqual(plan.rows.count, Fixture.rows / 4)
    }

    func testAResizedScreenReplacesItBecausePatchingCannotAddRows() {
        let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: screen(from: 0, count: Fixture.rows + 4))

        XCTAssertTrue(plan.replacesScreen)
    }

    func testTheFirstScreenReplacesTheEmptyPage() {
        XCTAssertTrue(TerminalHTMLRowDiff.plan(from: [], to: screen(from: 0)).replacesScreen)
    }

    func testBlankRowsDoNotInventAShift() {
        // Every row identical: many alignments match equally well, and none of
        // them is fewer rows than doing nothing.
        let blank = Array(repeating: "", count: Fixture.rows)

        XCTAssertTrue(TerminalHTMLRowDiff.plan(from: blank, to: blank).isEmpty)
    }

    func testAScrollOverBlankRowsStillFindsTheShift() {
        // The bottom half is blank, which is the ordinary state of a terminal
        // showing a short command's output.
        var before = screen(from: 0, count: Fixture.rows / 2)
        before += Array(repeating: "", count: Fixture.rows - before.count)
        var after = screen(from: 1, count: Fixture.rows / 2 - 1)
        after += Array(repeating: "", count: Fixture.rows - after.count)

        let plan = TerminalHTMLRowDiff.plan(from: before, to: after)

        XCTAssertEqual(plan.shift, 1)
        XCTAssertTrue(
            plan.rows.count < Fixture.rows,
            "a shift that reparses the whole screen is not a shift worth taking"
        )
    }

    /// The property that matters, stated as a property rather than a case.
    ///
    /// A scroll costs the rows it scrolled, until scrolling that far is no
    /// cheaper than starting the screen over.
    func testAScrollCostsTheRowsItScrolledOrElseOneReplacement() {
        for distance in 1..<Fixture.rows {
            let plan = TerminalHTMLRowDiff.plan(from: screen(from: 0), to: screen(from: distance))

            guard !plan.replacesScreen else {
                XCTAssertGreaterThanOrEqual(
                    distance,
                    Fixture.rows / 2,
                    "a short scroll must never fall back to a full rebuild"
                )
                continue
            }
            XCTAssertEqual(plan.rows.count, distance, "scroll of \(distance)")
            XCTAssertEqual(plan.shift, distance, "scroll of \(distance)")
        }
    }
}
