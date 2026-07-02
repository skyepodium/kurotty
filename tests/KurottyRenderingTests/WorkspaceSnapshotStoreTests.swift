import Foundation
import XCTest
@testable import KurottyApp

final class WorkspaceSnapshotStoreTests: XCTestCase {
    func testSaveAndLoadRoundTripSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore()
        let snapshot = makeSnapshot(windowID: "window-main", paneID: "pane-main")

        let saveReport = try store.save(snapshot, to: url)
        let loadResult = store.load(from: url)

        XCTAssertEqual(saveReport.snapshotURL, url)
        XCTAssertNil(saveReport.backupURL)
        guard case let .success(loadedSnapshot) = loadResult else {
            return XCTFail("Expected successful load, got \(loadResult)")
        }
        XCTAssertEqual(loadedSnapshot, snapshot)
    }

    func testSaveCreatesBackupWhenReplacingExistingSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore()
        let firstSnapshot = makeSnapshot(windowID: "window-first", paneID: "pane-first")
        let secondSnapshot = makeSnapshot(windowID: "window-second", paneID: "pane-second")

        _ = try store.save(firstSnapshot, to: url)
        let replacementReport = try store.save(secondSnapshot, to: url)

        let backupURL = try XCTUnwrap(replacementReport.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        guard case let .success(loadedSnapshot) = store.load(from: url) else {
            return XCTFail("Expected replacement snapshot to load")
        }
        guard case let .success(backupSnapshot) = store.load(from: backupURL) else {
            return XCTFail("Expected backup snapshot to load")
        }
        XCTAssertEqual(loadedSnapshot, secondSnapshot)
        XCTAssertEqual(backupSnapshot, firstSnapshot)
    }

    func testLoadReportsMissingFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("missing.json")
        let store = WorkspaceSnapshotStore()

        guard case let .missingFile(missingURL) = store.load(from: url) else {
            return XCTFail("Expected missing file report")
        }
        XCTAssertEqual(missingURL, url)
    }

    func testLoadReportsDecodeFailureForCorruptedJSON() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("workspace.json")
        try Data("{".utf8).write(to: url)
        let store = WorkspaceSnapshotStore()

        guard case let .decodeFailure(failedURL, _) = store.load(from: url) else {
            return XCTFail("Expected decode failure report")
        }
        XCTAssertEqual(failedURL, url)
    }

    func testLoadReportsSchemaMismatch() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore()
        let snapshot = makeSnapshot(windowID: "window-future", paneID: "pane-future", schemaVersion: 999)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url)

        guard case let .schemaMismatch(mismatchURL, expectedVersion, actualVersion) = store.load(from: url) else {
            return XCTFail("Expected schema mismatch report")
        }
        XCTAssertEqual(mismatchURL, url)
        XCTAssertEqual(expectedVersion, WorkspaceSnapshot.currentSchemaVersion)
        XCTAssertEqual(actualVersion, 999)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeSnapshot(
        windowID: WorkspaceWindowSnapshot.ID,
        paneID: WorkspacePaneSnapshot.ID,
        schemaVersion: Int = WorkspaceSnapshot.currentSchemaVersion
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            schemaVersion: schemaVersion,
            windows: [
                WorkspaceWindowSnapshot(
                    id: windowID,
                    title: "Workspace",
                    frame: WorkspaceWindowFrameSnapshot(x: 10, y: 20, width: 800, height: 600),
                    tabs: [
                        WorkspaceTabSnapshot(
                            id: "tab-main",
                            title: "Main",
                            root: .pane(WorkspacePaneSnapshot(
                                id: paneID,
                                title: "Shell",
                                workingDirectory: "/tmp/project",
                                profileName: "Default"
                            )),
                            activePaneID: paneID
                        ),
                    ],
                    activeTabID: "tab-main"
                ),
            ],
            activeWindowID: windowID
        )
    }
}
