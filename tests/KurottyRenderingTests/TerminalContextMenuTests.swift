import XCTest
@testable import KurottyApp

final class TerminalContextMenuTests: XCTestCase {
    func testContextMenuOmitsCopyWhenNoSelectionAndKeepsPasteDisabledWithoutClipboardText() {
        let entries = TerminalContextMenuBuilder.entries(
            for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: false)
        )

        XCTAssertEqual(entries.map(\.title), [
            "Paste",
            nil,
            "Split Right",
            "Split Left",
            "Split Down",
            "Split Up",
        ])
        XCTAssertFalse(entries.contains { $0.action == .copySelection })
        XCTAssertEqual(entries.first?.action, .paste)
        XCTAssertEqual(entries.first?.isEnabled, false)
    }

    func testContextMenuShowsCopyForSelectionAndEnablesPasteWithClipboardText() {
        let entries = TerminalContextMenuBuilder.entries(
            for: TerminalContextMenuState(hasSelection: true, hasPasteboardText: true)
        )

        XCTAssertEqual(entries.map(\.title), [
            "Copy",
            "Paste",
            nil,
            "Split Right",
            "Split Left",
            "Split Down",
            "Split Up",
        ])
        XCTAssertEqual(entries[0].action, .copySelection)
        XCTAssertEqual(entries[0].isEnabled, true)
        XCTAssertEqual(entries[1].action, .paste)
        XCTAssertEqual(entries[1].isEnabled, true)
    }

    func testContextMenuSplitActionsMapToFourDirections() {
        let splitActions = TerminalContextMenuBuilder.entries(
            for: TerminalContextMenuState(hasSelection: true, hasPasteboardText: true)
        )
            .compactMap(\.action)
            .compactMap(\.splitDirection)

        XCTAssertEqual(splitActions, [.right, .left, .down, .up])
    }
}
