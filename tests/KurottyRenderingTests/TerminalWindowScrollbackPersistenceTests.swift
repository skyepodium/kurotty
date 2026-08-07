import AppKit
import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// End-to-end coverage for the scrollback persistence call sites: capture into a
/// workspace descriptor, display-only replay back into the matching pane, and
/// pruning of snapshots no live pane references.
@MainActor
final class TerminalWindowScrollbackPersistenceTests: XCTestCase {
    private enum Fixture {
        static let paneText = "restored-scrollback-line"
        static let orphanRef = "v2-0123456789abcdef0123456789abcdef"
        static let orphanPayload = "orphan"
    }

    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-scrollback-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    private func makeWindowController(isEnabled: Bool = true) -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        controller.scrollbackSnapshotCoordinator = TerminalScrollbackSnapshotCoordinator(
            store: TerminalScrollbackSnapshotStore(rootURL: rootURL),
            isEnabled: isEnabled
        )
        return controller
    }

    /// Paints text into the window's single pane through the same display-only
    /// ingest point the replayer uses.
    private func paintFirstPane(of controller: TerminalWindowController, text: String) throws {
        let splitView = try XCTUnwrap(controller.selectedSplitViewForTesting)
        let pane = try XCTUnwrap(splitView.terminalPanesInLayoutOrder.first)
        pane.terminalSurface.consumeReplayedScrollback(text + "\r\n")
    }

    private func store() -> TerminalScrollbackSnapshotStore {
        TerminalScrollbackSnapshotStore(rootURL: rootURL)
    }

    private func waitForWrites(_ controller: TerminalWindowController) {
        controller.flushScrollbackSnapshotWrites()
    }

    // MARK: - Capture

    func testCapturingDescriptorWritesASnapshotAndRecordsItsRef() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        try paintFirstPane(of: controller, text: Fixture.paneText)

        let descriptor = controller.workspaceDescriptor(capturingScrollback: true)
        waitForWrites(controller)

        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(from: descriptor)
        let refs = snapshot.scrollbackSnapshotRefs
        XCTAssertEqual(refs.count, 1, "the window's single pane must contribute one snapshot reference")
        let ref = try XCTUnwrap(refs.first)
        let payload = try XCTUnwrap(store().read(ref: ref))
        XCTAssertTrue(
            String(decoding: payload, as: UTF8.self).contains(Fixture.paneText),
            "the stored snapshot must contain the pane's painted text"
        )
    }

    func testLayoutOnlyDescriptorWritesNoSnapshot() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        try paintFirstPane(of: controller, text: Fixture.paneText)

        let descriptor = controller.layoutOnlyWorkspaceDescriptor()
        waitForWrites(controller)

        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(from: descriptor)
        XCTAssertTrue(snapshot.scrollbackSnapshotRefs.isEmpty)
        XCTAssertTrue(store().snapshotFileURLs().isEmpty)
    }

    func testCaptureWritesNothingWhenTheSettingIsOff() throws {
        let controller = makeWindowController(isEnabled: false)
        defer { controller.close() }
        try paintFirstPane(of: controller, text: Fixture.paneText)

        let descriptor = controller.workspaceDescriptor(capturingScrollback: true)
        waitForWrites(controller)

        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(from: descriptor)
        XCTAssertTrue(snapshot.scrollbackSnapshotRefs.isEmpty)
        XCTAssertTrue(store().snapshotFileURLs().isEmpty)
    }

    // MARK: - Restore

    func testRestoreFeedsTheSnapshotBackIntoTheMatchingPaneAndClearsTheReplayFlag() throws {
        let source = makeWindowController()
        try paintFirstPane(of: source, text: Fixture.paneText)
        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(
            from: source.workspaceDescriptor(capturingScrollback: true)
        )
        waitForWrites(source)
        source.close()

        let restored = makeWindowController()
        defer { restored.close() }
        let pane = try XCTUnwrap(restored.selectedSplitViewForTesting?.terminalPanesInLayoutOrder.first)
        XCTAssertFalse(pane.terminalSurface.isReplayingScrollback)

        let reports = restored.restoreScrollback(from: snapshot)

        let paneID = try XCTUnwrap(snapshot.restorePlan.scrollbackReplayCandidates.first?.paneID.rawValue)
        let report = try XCTUnwrap(reports[paneID])
        XCTAssertTrue(report.didMarkReplayFlag, "the replay flag must be raised while restored bytes are parsed")
        XCTAssertGreaterThan(report.byteCount, 0)
        XCTAssertTrue(
            report.isFlagClearedAfterReplay,
            "the flag must be lowered again or the live shell stops receiving real capability replies"
        )
        XCTAssertFalse(pane.terminalSurface.isReplayingScrollback)
        XCTAssertTrue(
            paneTextContains(pane: pane, text: Fixture.paneText),
            "restored bytes must land in the pane's own screen model"
        )
    }

    func testRestoreDoesNothingWhenTheSettingIsOff() throws {
        let source = makeWindowController()
        try paintFirstPane(of: source, text: Fixture.paneText)
        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(
            from: source.workspaceDescriptor(capturingScrollback: true)
        )
        waitForWrites(source)
        source.close()

        let restored = makeWindowController(isEnabled: false)
        defer { restored.close() }

        let reports = restored.restoreScrollback(from: snapshot)

        XCTAssertEqual(reports.values.map(\.byteCount), [0])
        XCTAssertEqual(reports.values.map(\.didMarkReplayFlag), [false])
        let pane = try XCTUnwrap(restored.selectedSplitViewForTesting?.terminalPanesInLayoutOrder.first)
        XCTAssertFalse(paneTextContains(pane: pane, text: Fixture.paneText))
    }

    /// Restored scrollback is display-only, so it must never turn into a command
    /// the shell could run.
    func testRestoringScrollbackNeverCreatesACommandReplayCandidate() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        try paintFirstPane(of: controller, text: Fixture.paneText)

        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(
            from: controller.workspaceDescriptor(capturingScrollback: true)
        )

        XCTAssertFalse(snapshot.restorePlan.scrollbackReplayCandidates.isEmpty)
        XCTAssertTrue(snapshot.restorePlan.commandReplayCandidates.isEmpty)
        XCTAssertTrue(snapshot.unsafeCommandReplayPaneIDs.isEmpty)
    }

    // MARK: - Prune

    func testPruneRemovesSnapshotsNoLivePaneReferences() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        try paintFirstPane(of: controller, text: Fixture.paneText)

        let snapshot = WorkspaceSnapshotCoordinator().makeLayoutOnlySnapshot(
            from: controller.workspaceDescriptor(capturingScrollback: true)
        )
        waitForWrites(controller)
        _ = try store().write(ref: Fixture.orphanRef, payload: Data(Fixture.orphanPayload.utf8))
        XCTAssertEqual(store().snapshotFileURLs().count, 2)

        controller.pruneScrollbackSnapshots(retaining: snapshot)
        waitForWrites(controller)

        XCTAssertNil(store().read(ref: Fixture.orphanRef), "an unreferenced snapshot must be deleted")
        XCTAssertEqual(
            Set(store().snapshotFileURLs().map { $0.deletingPathExtension().lastPathComponent }),
            snapshot.scrollbackSnapshotRefs
        )
    }

    // MARK: - Helpers

    private func paneTextContains(pane: TerminalPaneView, text: String) -> Bool {
        pane.terminalSurface.persistableScrollbackRows()
            .map { row in String(row.map(\.character)) }
            .contains { $0.contains(text) }
    }
}
