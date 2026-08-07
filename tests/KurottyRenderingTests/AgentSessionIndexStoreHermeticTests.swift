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

    func testTheSharedStorePublishesNoProvenanceUnderTest() {
        XCTAssertTrue(AgentSessionIndexStore.shared.provenance.isEmpty)
    }

    /// One transcript on disk, scanned end to end, becomes one answerable
    /// question: which file did the agent write, and from which prompt.
    func testAScannedTranscriptPublishesFileProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-provenance-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let editedPath = "/Users/tester/dev/project/Sources/App/Greeting.swift"
        let prompt = "Rename the greeting helper"
        let transcript = """
        {"type":"user","sessionId":"session-1","cwd":"/Users/tester/dev/project",\
        "timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"\(prompt)"}}
        {"type":"assistant","sessionId":"session-1","timestamp":"2026-08-01T10:00:05.000Z",\
        "message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Edit",\
        "input":{"file_path":"\(editedPath)","old_string":"a","new_string":"b"}}]}}
        """
        try transcript.write(
            to: projects.appendingPathComponent("session-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let store = AgentSessionIndexStore(
            homeDirectory: root,
            isIndexingEnabled: true,
            observesSettingsChanges: false
        )
        store.refresh()
        try await waitForScan(of: store)

        let touch = try XCTUnwrap(store.provenance.mostRecentTouch(forAbsolutePath: editedPath))
        XCTAssertEqual(touch.agent, .claudeCode)
        XCTAssertEqual(touch.sessionID, "session-1")
        XCTAssertEqual(touch.promptExcerpt, prompt)
        XCTAssertEqual(touch.kind, .edited)
        XCTAssertTrue(
            store.provenance.hasRecentChange(
                atOrUnder: "/Users/tester/dev/project",
                now: touch.changedAt
            )
        )

        // Turning indexing off drops the attribution with the records.
        store.setIndexingEnabled(false)
        XCTAssertTrue(store.provenance.isEmpty)
    }

    /// The index is a cache of what is already on disk, so it must not write a
    /// second copy anywhere: transcripts contain prompts and file paths, and a
    /// persisted index would put them somewhere the user never consented to.
    ///
    /// Replaces a source-text test that grepped `AgentSessionIndexStore.swift`
    /// for `data.write(`, `createDirectory(` and `JSONEncoder(` — which would
    /// have passed just as happily if the writing moved one file over.
    func testAFullScanWritesNothingOutsideTheTranscriptsItRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-nopersist-\(UUID().uuidString)", isDirectory: true)
        let projects = root.appendingPathComponent(".claude/projects/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let transcript = """
        {"type":"user","sessionId":"session-1","cwd":"/Users/tester/dev/project",\
        "timestamp":"2026-08-01T10:00:00.000Z","message":{"role":"user","content":"hello"}}
        """
        try transcript.write(
            to: projects.appendingPathComponent("session-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let before = try filePaths(under: root)

        let store = AgentSessionIndexStore(
            homeDirectory: root,
            isIndexingEnabled: true,
            observesSettingsChanges: false
        )
        store.refresh()
        try await waitForScan(of: store)

        XCTAssertFalse(store.records.isEmpty, "the scan must actually have read something")
        XCTAssertEqual(try filePaths(under: root), before, "the index must stay in memory")
    }

    private func filePaths(under root: URL) throws -> Set<String> {
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        return Set((enumerator?.allObjects as? [String]) ?? [])
    }

    private func waitForScan(of store: AgentSessionIndexStore) async throws {
        for _ in 0..<Fixture.scanPollCount {
            if store.hasCompletedInitialScan, !store.isScanning {
                return
            }
            try await Task.sleep(nanoseconds: Fixture.scanPollIntervalNANOS)
        }
        XCTFail("the background scan did not complete")
    }

    private enum Fixture {
        static let scanPollCount = 200
        static let scanPollIntervalNANOS: UInt64 = 10_000_000
    }
}
