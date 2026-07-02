import XCTest
@testable import KurottyApp

final class TerminalCommandHistoryNavigatorTests: XCTestCase {
    func testLatestAndAdjacentNavigationRespectBoundaries() throws {
        let navigator = TerminalCommandHistoryNavigator(spans: [
            makeSpan(id: 10, commandText: "swift build"),
            makeSpan(id: 20, commandText: "swift test"),
            makeSpan(id: 30, commandText: "git status"),
        ])

        XCTAssertEqual(navigator.latest()?.id, 30)
        XCTAssertNil(navigator.previous(from: 10))
        XCTAssertEqual(navigator.previous(from: 20)?.id, 10)
        XCTAssertEqual(navigator.next(from: 20)?.id, 30)
        XCTAssertNil(navigator.next(from: 30))
        XCTAssertNil(navigator.previous(from: 999))
        XCTAssertNil(navigator.next(from: 999))
    }

    func testSearchFiltersByTextCwdAndExitCode() {
        let navigator = TerminalCommandHistoryNavigator(spans: [
            makeSpan(id: 1, cwd: "/repo/a", exitCode: 0, commandText: "swift test"),
            makeSpan(id: 2, cwd: "/repo/b", exitCode: 1, commandText: "swift build"),
            makeSpan(id: 3, cwd: "/repo/a", exitCode: 1, commandText: nil),
            makeSpan(id: 4, cwd: "/repo/a", exitCode: 1, commandText: "git status"),
        ])

        XCTAssertEqual(navigator.search(cwd: "/repo/a").map(\.id), [1, 3, 4])
        XCTAssertEqual(navigator.search(exitCode: 1).map(\.id), [2, 3, 4])
        XCTAssertEqual(navigator.search(text: "BUILD").map(\.id), [2])
        XCTAssertEqual(navigator.search(cwd: "/repo/a", exitCode: 1, text: "git").map(\.id), [4])
        XCTAssertTrue(navigator.search(cwd: "/repo/a", exitCode: 1, text: "swift").isEmpty)
    }

    func testFoldStateTogglesCollapsedCommandIDs() {
        var foldState = TerminalCommandOutputFoldState()

        XCTAssertFalse(foldState.isCollapsed(spanID: 42))
        XCTAssertTrue(foldState.isExpanded(spanID: 42))

        foldState.toggle(spanID: 42)

        XCTAssertTrue(foldState.isCollapsed(spanID: 42))
        XCTAssertFalse(foldState.isExpanded(spanID: 42))

        foldState.toggle(spanID: 42)

        XCTAssertFalse(foldState.isCollapsed(spanID: 42))
        XCTAssertTrue(foldState.isExpanded(spanID: 42))
    }

    func testNavigationAndSearchPreserveInputOrdering() {
        let navigator = TerminalCommandHistoryNavigator(spans: [
            makeSpan(id: 30, cwd: "/repo", commandText: "third"),
            makeSpan(id: 10, cwd: "/repo", commandText: "first"),
            makeSpan(id: 20, cwd: "/repo", commandText: "second"),
        ])

        XCTAssertEqual(navigator.latest()?.id, 20)
        XCTAssertEqual(navigator.previous(from: 10)?.id, 30)
        XCTAssertEqual(navigator.next(from: 10)?.id, 20)
        XCTAssertEqual(navigator.search(cwd: "/repo").map(\.id), [30, 10, 20])
    }

    private func makeSpan(
        id: Int,
        cwd: String? = nil,
        exitCode: Int? = nil,
        commandText: String? = nil
    ) -> TerminalCommandSpan {
        TerminalCommandSpan(
            id: id,
            cwd: cwd,
            startBoundarySequence: id,
            endBoundarySequence: id + 1,
            exitCode: exitCode,
            promptBoundarySequence: id - 1,
            outputBoundarySequence: id,
            commandText: commandText
        )
    }
}
