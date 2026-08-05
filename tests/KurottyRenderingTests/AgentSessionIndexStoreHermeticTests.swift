import Foundation
import XCTest
@testable import KurottyApp

/// The shared index store scans every transcript under the real home directory
/// on a detached task. Two problems under XCTest: the suite reads whatever is
/// in the developer's `~/.claude`, and the scan outlives the test that started
/// it while still holding a hop back to the main actor.
@MainActor
final class AgentSessionIndexStoreHermeticTests: XCTestCase {
    func testTheHarnessIsDetected() {
        // If this ever stops being true the gate below silently stops working,
        // and the suite goes back to reading the developer's home directory.
        XCTAssertTrue(AgentSessionIndexStore.isRunningUnderXCTest)
    }

    func testTheSharedStoreDoesNotIndexUnderTest() {
        XCTAssertFalse(AgentSessionIndexStore.shared.isIndexingEnabled)
        XCTAssertTrue(AgentSessionIndexStore.shared.records.isEmpty)
    }

    func testATestOwnedStoreStillIndexesItsOwnDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-index-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let store = AgentSessionIndexStore(
            homeDirectory: root,
            isIndexingEnabled: true,
            observesSettingsChanges: false
        )
        XCTAssertTrue(store.isIndexingEnabled)
    }
}
