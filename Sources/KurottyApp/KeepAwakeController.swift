import Foundation
import IOKit.pwr_mgt

typealias KeepAwakeAssertionID = IOPMAssertionID

protocol KeepAwakeAssertionProvider {
    func acquire(reason: String) -> KeepAwakeAssertionID?
    func release(_ assertionID: KeepAwakeAssertionID)
}

struct IOPMKeepAwakeAssertionProvider: KeepAwakeAssertionProvider {
    func acquire(reason: String) -> KeepAwakeAssertionID? {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            return nil
        }
        return assertionID
    }

    func release(_ assertionID: KeepAwakeAssertionID) {
        IOPMAssertionRelease(assertionID)
    }
}

final class KeepAwakeController {
    private let assertionProvider: KeepAwakeAssertionProvider
    private let reason: String
    private var assertionID: KeepAwakeAssertionID?

    init(
        assertionProvider: KeepAwakeAssertionProvider = IOPMKeepAwakeAssertionProvider(),
        reason: String = "Kurotty is keeping the Mac awake"
    ) {
        self.assertionProvider = assertionProvider
        self.reason = reason
    }

    deinit {
        releaseAssertion()
    }

    var isEnabled: Bool {
        assertionID != nil
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool) -> Bool {
        if isEnabled {
            return acquireAssertionIfNeeded()
        }
        releaseAssertion()
        return true
    }

    func invalidate() {
        releaseAssertion()
    }

    private func acquireAssertionIfNeeded() -> Bool {
        guard assertionID == nil else {
            return true
        }
        guard let assertionID = assertionProvider.acquire(reason: reason) else {
            return false
        }
        self.assertionID = assertionID
        return true
    }

    private func releaseAssertion() {
        guard let assertionID else {
            return
        }
        self.assertionID = nil
        assertionProvider.release(assertionID)
    }
}
