import Foundation
import XCTest
@testable import KurottyApp

final class WorkspaceSnapshotCoordinatorTests: XCTestCase {
    func testMakeLayoutOnlySnapshotBuildsWorkspaceStructureFromDescriptors() {
        let coordinator = WorkspaceSnapshotCoordinator()
        let descriptor = makeDescriptor()

        let snapshot = coordinator.makeLayoutOnlySnapshot(from: descriptor)

        XCTAssertEqual(snapshot.schemaVersion, WorkspaceSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.activeWindowID, "window-main")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "window-main")
        XCTAssertEqual(snapshot.windows[0].title, "Main Window")
        XCTAssertEqual(snapshot.windows[0].frame, WorkspaceWindowFrameSnapshot(
            x: 20,
            y: 40,
            width: 1200,
            height: 800
        ))
        XCTAssertEqual(snapshot.windows[0].activeTabID, "tab-work")
        XCTAssertEqual(snapshot.windows[0].tabs.count, 1)
        XCTAssertEqual(snapshot.windows[0].tabs[0].id, "tab-work")
        XCTAssertEqual(snapshot.windows[0].tabs[0].title, "Work")
        XCTAssertEqual(snapshot.windows[0].tabs[0].activePaneID, "pane-editor")
        XCTAssertEqual(snapshot.windows[0].tabs[0].root.paneIDs, [
            "pane-shell",
            "pane-editor",
        ])
    }

    func testMakeLayoutOnlySnapshotDoesNotCaptureProcessRestoreMetadata() {
        let coordinator = WorkspaceSnapshotCoordinator()
        let descriptor = WorkspaceSnapshotCoordinator.WorkspaceDescriptor(
            windows: [
                WorkspaceSnapshotCoordinator.WindowDescriptor(
                    id: "window-main",
                    tabs: [
                        WorkspaceSnapshotCoordinator.TabDescriptor(
                            id: "tab-main",
                            root: .pane(WorkspaceSnapshotCoordinator.PaneDescriptor(
                                id: "pane-main",
                                title: "swift test",
                                workingDirectory: "/tmp/project",
                                profileName: "Default"
                            )),
                            activePaneID: "pane-main"
                        ),
                    ],
                    activeTabID: "tab-main"
                ),
            ],
            activeWindowID: "window-main"
        )

        let snapshot = coordinator.makeLayoutOnlySnapshot(from: descriptor)

        guard case let .pane(pane) = snapshot.windows[0].tabs[0].root else {
            return XCTFail("Expected a pane root")
        }
        XCTAssertEqual(pane.title, "swift test")
        XCTAssertEqual(pane.workingDirectory, "/tmp/project")
        XCTAssertEqual(pane.profileName, "Default")
        XCTAssertNil(pane.restoreSafety.commandLine)
        XCTAssertEqual(pane.restoreSafety.commandReplay, .disabled)
        XCTAssertFalse(pane.restoreSafety.capturedAtPromptBoundary)
        XCTAssertFalse(pane.restoreSafety.allowsAutomaticProcessRestore)
        XCTAssertEqual(snapshot.unsafeCommandReplayPaneIDs, [])
    }

    func testSaveLayoutOnlySnapshotPersistsThroughWorkspaceSnapshotStore() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("workspace.json")
        let store = WorkspaceSnapshotStore()
        let coordinator = WorkspaceSnapshotCoordinator(store: store)
        let descriptor = makeDescriptor()

        let report = try coordinator.saveLayoutOnlySnapshot(from: descriptor, to: url)
        let loadResult = store.load(from: url)

        XCTAssertEqual(report.snapshotURL, url)
        XCTAssertNil(report.backupURL)
        guard case let .success(loadedSnapshot) = loadResult else {
            return XCTFail("Expected successful load, got \(loadResult)")
        }
        XCTAssertEqual(loadedSnapshot, coordinator.makeLayoutOnlySnapshot(from: descriptor))
    }

    private func makeDescriptor() -> WorkspaceSnapshotCoordinator.WorkspaceDescriptor {
        WorkspaceSnapshotCoordinator.WorkspaceDescriptor(
            windows: [
                WorkspaceSnapshotCoordinator.WindowDescriptor(
                    id: "window-main",
                    title: "Main Window",
                    frame: WorkspaceWindowFrameSnapshot(
                        x: 20,
                        y: 40,
                        width: 1200,
                        height: 800
                    ),
                    tabs: [
                        WorkspaceSnapshotCoordinator.TabDescriptor(
                            id: "tab-work",
                            title: "Work",
                            root: .split(WorkspaceSnapshotCoordinator.SplitDescriptor(
                                id: "split-root",
                                axis: .vertical,
                                children: [
                                    .pane(WorkspaceSnapshotCoordinator.PaneDescriptor(
                                        id: "pane-shell",
                                        title: "zsh",
                                        workingDirectory: "/Users/skye/project",
                                        profileName: "Default"
                                    )),
                                    .pane(WorkspaceSnapshotCoordinator.PaneDescriptor(
                                        id: "pane-editor",
                                        title: "vim",
                                        workingDirectory: "/Users/skye/project",
                                        profileName: "Editor"
                                    )),
                                ],
                                proportions: [0.4, 0.6]
                            )),
                            activePaneID: "pane-editor"
                        ),
                    ],
                    activeTabID: "tab-work"
                ),
            ],
            activeWindowID: "window-main"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceSnapshotCoordinatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
