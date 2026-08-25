import AppKit
import XCTest

@testable import KurottyApp

@MainActor
final class KurottyWindowCollectionBehaviorTests: XCTestCase {
    func testTerminalWindowBehaviorOptsIntoNativeFullscreenTiling() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )

        KurottyWindowCollectionBehavior.apply(to: window)

        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.collectionBehavior.contains(.managed))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
    }
}
