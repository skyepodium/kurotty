import XCTest

@testable import KurottyApp

final class KeepAwakeControllerTests: XCTestCase {
    private final class RecordingAssertionProvider: KeepAwakeAssertionProvider {
        var acquiredReasons: [String] = []
        var releasedIDs: [KeepAwakeAssertionID] = []
        var nextIDs: [KeepAwakeAssertionID?] = [42]

        func acquire(reason: String) -> KeepAwakeAssertionID? {
            acquiredReasons.append(reason)
            return nextIDs.isEmpty ? nil : nextIDs.removeFirst()
        }

        func release(_ assertionID: KeepAwakeAssertionID) {
            releasedIDs.append(assertionID)
        }
    }

    func testEnablingAcquiresOneAssertionAndDisablingReleasesIt() {
        let provider = RecordingAssertionProvider()
        let controller = KeepAwakeController(assertionProvider: provider, reason: "test awake")

        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(provider.acquiredReasons, ["test awake"])

        XCTAssertTrue(controller.setEnabled(false))
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(provider.releasedIDs, [42])
    }

    func testEnablingTwiceDoesNotAcquireTwice() {
        let provider = RecordingAssertionProvider()
        let controller = KeepAwakeController(assertionProvider: provider)

        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertTrue(controller.setEnabled(true))

        XCTAssertEqual(provider.acquiredReasons.count, 1)
        XCTAssertTrue(provider.releasedIDs.isEmpty)
    }

    func testFailedAcquireLeavesTheToggleOff() {
        let provider = RecordingAssertionProvider()
        provider.nextIDs = [nil]
        let controller = KeepAwakeController(assertionProvider: provider)

        XCTAssertFalse(controller.setEnabled(true))

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(provider.releasedIDs.isEmpty)
    }

    func testInvalidateReleasesActiveAssertionForQuit() {
        let provider = RecordingAssertionProvider()
        let controller = KeepAwakeController(assertionProvider: provider)

        XCTAssertTrue(controller.setEnabled(true))
        controller.invalidate()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(provider.releasedIDs, [42])
    }
}
