import AppKit
import XCTest
@testable import KurottyApp

final class TerminalWindowInteractionTests: XCTestCase {
    func testTabMouseActionClosesWhenClickIsInsideCloseButtonFrame() {
        let closeFrame = NSRect(x: 90, y: 8, width: 18, height: 18)

        let action = TerminalTabMouseActionResolver.action(
            for: NSPoint(x: 96, y: 14),
            closeButtonFrame: closeFrame
        )

        XCTAssertEqual(action, .close)
    }

    func testTabMouseActionSelectsWhenClickIsOutsideCloseButtonFrame() {
        let closeFrame = NSRect(x: 90, y: 8, width: 18, height: 18)

        let action = TerminalTabMouseActionResolver.action(
            for: NSPoint(x: 40, y: 14),
            closeButtonFrame: closeFrame
        )

        XCTAssertEqual(action, .select)
    }

    func testNotificationDeliveryPolicyDoesNotSuppressFocusedTerminalNotifications() {
        XCTAssertTrue(TerminalNotificationDeliveryPolicy.shouldDeliverUserNotification(isTerminalFocusedForUser: true))
        XCTAssertTrue(TerminalNotificationDeliveryPolicy.shouldDeliverUserNotification(isTerminalFocusedForUser: false))
    }
}
