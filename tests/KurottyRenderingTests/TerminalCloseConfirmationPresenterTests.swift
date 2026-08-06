import XCTest
@testable import KurottyApp

/// The close guard used to reach `NSAlert.runModal()` unconditionally, which
/// blocks until a click. Under XCTest there is nobody to click, so a test that
/// closed a tab with a live child hung the process — and a hung test run looks
/// exactly like a slow one.
@MainActor
final class TerminalCloseConfirmationPresenterTests: XCTestCase {
    override func tearDown() {
        TerminalCloseConfirmation.presenterOverride = nil
        super.tearDown()
    }

    func testRunningUnderTestIsDetected() {
        XCTAssertTrue(TerminalCloseConfirmation.isRunningUnderTest)
    }

    func testWithoutAnOverrideTheGuardResolvesInsteadOfPresenting() {
        TerminalCloseConfirmation.presenterOverride = nil
        // nil would mean "raise the modal", which is the hang.
        XCTAssertEqual(
            TerminalCloseConfirmation.resolvedWithoutPresenting(processNames: ["npm"]),
            true
        )
    }

    func testAnOverrideDecidesAndReceivesTheProcessNames() {
        var seen: [String]?
        TerminalCloseConfirmation.presenterOverride = { names in
            seen = names
            return false
        }
        XCTAssertEqual(
            TerminalCloseConfirmation.resolvedWithoutPresenting(processNames: ["npm", "cargo"]),
            false
        )
        XCTAssertEqual(seen, ["npm", "cargo"])
    }

    func testAnOverrideCanAlsoAllowTheClose() {
        TerminalCloseConfirmation.presenterOverride = { _ in true }
        XCTAssertEqual(
            TerminalCloseConfirmation.resolvedWithoutPresenting(processNames: ["vim"]),
            true
        )
    }
}
