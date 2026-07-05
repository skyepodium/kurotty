import XCTest
@testable import KurottyApp

final class WorkspaceSnapshotTests: XCTestCase {
    func testWorkspaceSnapshotCodableRoundTripPreservesWindowTabsSplitsAndPanes() throws {
        let activePaneID = WorkspacePaneSnapshot.ID("pane-editor")
        let snapshot = WorkspaceSnapshot(
            windows: [
                WorkspaceWindowSnapshot(
                    id: WorkspaceWindowSnapshot.ID("window-main"),
                    title: "Main Workspace",
                    tabs: [
                        WorkspaceTabSnapshot(
                            id: WorkspaceTabSnapshot.ID("tab-work"),
                            title: "Work",
                            root: .split(WorkspaceSplitSnapshot(
                                id: WorkspaceSplitSnapshot.ID("split-root"),
                                axis: .vertical,
                                children: [
                                    .pane(WorkspacePaneSnapshot(
                                        id: WorkspacePaneSnapshot.ID("pane-shell"),
                                        title: "~/repo (-zsh)",
                                        workingDirectory: "/Users/skye/repo",
                                        profileName: "Default"
                                    )),
                                    .split(WorkspaceSplitSnapshot(
                                        id: WorkspaceSplitSnapshot.ID("split-right"),
                                        axis: .horizontal,
                                        children: [
                                            .pane(WorkspacePaneSnapshot(
                                                id: activePaneID,
                                                title: "vim",
                                                workingDirectory: "/Users/skye/repo",
                                                profileName: "Editor"
                                            )),
                                            .pane(WorkspacePaneSnapshot(
                                                id: WorkspacePaneSnapshot.ID("pane-tests"),
                                                title: "swift test",
                                                workingDirectory: "/Users/skye/repo",
                                                profileName: "Default"
                                            )),
                                        ],
                                        proportions: [0.65, 0.35]
                                    )),
                                ],
                                proportions: [0.4, 0.6]
                            )),
                            activePaneID: activePaneID
                        ),
                    ],
                    activeTabID: WorkspaceTabSnapshot.ID("tab-work")
                ),
            ],
            activeWindowID: WorkspaceWindowSnapshot.ID("window-main")
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.windows[0].activeTabID, WorkspaceTabSnapshot.ID("tab-work"))
        XCTAssertEqual(decoded.windows[0].tabs[0].activePaneID, activePaneID)
        XCTAssertEqual(decoded.windows[0].tabs[0].root.paneIDs, [
            WorkspacePaneSnapshot.ID("pane-shell"),
            WorkspacePaneSnapshot.ID("pane-editor"),
            WorkspacePaneSnapshot.ID("pane-tests"),
        ])
    }

    func testWorkspaceSnapshotDefaultsToLayoutOnlyRestoreForProcessMetadata() {
        let pane = WorkspacePaneSnapshot(
            id: WorkspacePaneSnapshot.ID("pane-build"),
            title: "build",
            workingDirectory: "/tmp/project",
            profileName: "Default",
            restoreSafety: TerminalRestoreSafetyMetadata(
                commandLine: "swift test",
                commandReplay: .requiresExplicitOptIn,
                capturedAtPromptBoundary: true
            )
        )

        XCTAssertEqual(pane.restoreSafety.commandReplay, .requiresExplicitOptIn)
        XCTAssertFalse(pane.restoreSafety.allowsAutomaticProcessRestore)
        XCTAssertEqual(pane.restoreSafety.commandReplayRisk, .requiresExplicitOptIn)
    }

    func testWorkspaceSnapshotFlagsUnsafeCommandReplayRequests() {
        let unsafePane = WorkspacePaneSnapshot(
            id: WorkspacePaneSnapshot.ID("pane-danger"),
            title: "deploy",
            workingDirectory: "/tmp/project",
            profileName: "Production",
            restoreSafety: TerminalRestoreSafetyMetadata(
                commandLine: "deploy --prod",
                commandReplay: .optedIn,
                capturedAtPromptBoundary: false
            )
        )
        let snapshot = WorkspaceSnapshot(
            windows: [
                WorkspaceWindowSnapshot(
                    id: WorkspaceWindowSnapshot.ID("window-main"),
                    tabs: [
                        WorkspaceTabSnapshot(
                            id: WorkspaceTabSnapshot.ID("tab-main"),
                            root: .pane(unsafePane),
                            activePaneID: unsafePane.id
                        ),
                    ],
                    activeTabID: WorkspaceTabSnapshot.ID("tab-main")
                ),
            ],
            activeWindowID: WorkspaceWindowSnapshot.ID("window-main")
        )

        XCTAssertEqual(unsafePane.restoreSafety.commandReplayRisk, .unsafePromptState)
        XCTAssertEqual(snapshot.unsafeCommandReplayPaneIDs, [unsafePane.id])
    }

    func testWorkspaceRestorePlanSeparatesLayoutFromExplicitProcessActions() {
        let safePane = WorkspacePaneSnapshot(
            id: "pane-safe",
            title: "server",
            workingDirectory: "/tmp/project",
            restoreSafety: TerminalRestoreSafetyMetadata(
                commandLine: "npm run dev",
                commandReplay: .optedIn,
                capturedAtPromptBoundary: true
            )
        )
        let reviewPane = WorkspacePaneSnapshot(
            id: "pane-review",
            title: "deploy",
            workingDirectory: "/tmp/project",
            restoreSafety: TerminalRestoreSafetyMetadata(
                commandLine: "deploy --prod",
                commandReplay: .requiresExplicitOptIn,
                capturedAtPromptBoundary: false
            )
        )
        let layoutPane = WorkspacePaneSnapshot(id: "pane-layout")
        let snapshot = WorkspaceSnapshot(
            windows: [
                WorkspaceWindowSnapshot(
                    id: "window-main",
                    tabs: [
                        WorkspaceTabSnapshot(
                            id: "tab-main",
                            root: .split(WorkspaceSplitSnapshot(
                                id: "split-main",
                                axis: .vertical,
                                children: [
                                    .pane(safePane),
                                    .pane(reviewPane),
                                    .pane(layoutPane),
                                ]
                            ))
                        ),
                    ]
                ),
            ]
        )

        let plan = snapshot.restorePlan

        XCTAssertEqual(plan.layoutPaneIDs, ["pane-safe", "pane-review", "pane-layout"])
        XCTAssertEqual(plan.processRestorePaneIDs, [])
        XCTAssertEqual(plan.commandReplayCandidates.map(\.paneID), ["pane-safe", "pane-review"])
        XCTAssertEqual(plan.commandReplayCandidates.map(\.approval), [.alreadyOptedIn, .requiresExplicitOptIn])
        XCTAssertEqual(plan.commandReplayCandidates.map(\.risk), [.none, .requiresExplicitOptIn])
        XCTAssertFalse(plan.canAutomaticallyRestoreProcesses)
    }
}
