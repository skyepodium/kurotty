import XCTest
@testable import KurottyApp

/// The close button stays laid out when it is invisible, so its frame alone
/// cannot decide whether a click closes the tab.
final class TerminalTabItemHitTestTests: XCTestCase {
    private let closeButtonFrame = CGRect(x: 96, y: 6, width: 16, height: 16)

    func testClickOnAVisibleCloseButtonCloses() {
        XCTAssertTrue(TerminalTabItemView.closesTab(
            atLocation: CGPoint(x: 104, y: 14),
            closeButtonFrame: closeButtonFrame,
            closeButtonAlpha: 1
        ))
    }

    func testClickWhereAnInvisibleCloseButtonSitsSelectsInstead() {
        // The background-window case: hover never fired, so the button is at
        // alpha 0 and the user is aiming at the tab, not at a close control.
        XCTAssertFalse(TerminalTabItemView.closesTab(
            atLocation: CGPoint(x: 104, y: 14),
            closeButtonFrame: closeButtonFrame,
            closeButtonAlpha: 0
        ))
    }

    func testClickOutsideTheCloseButtonSelectsEvenWhenVisible() {
        XCTAssertFalse(TerminalTabItemView.closesTab(
            atLocation: CGPoint(x: 20, y: 14),
            closeButtonFrame: closeButtonFrame,
            closeButtonAlpha: 1
        ))
    }
}
