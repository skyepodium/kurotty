import Foundation
import KurottyCore

/// Ties the three halves of scrollback persistence together: serializing a
/// pane's trailing rows, writing them off the main actor, and replaying them
/// back into a restored pane for display only.
///
/// The coordinator owns nothing global. A window controller creates one, hands
/// it the snapshot root, and drops it when the workspace goes away.
@MainActor
final class TerminalScrollbackSnapshotCoordinator {
    /// Everything needed to persist one pane. Rows are copied out of the live
    /// buffer on the main actor and serialized before the write is enqueued, so
    /// the background queue never touches terminal state.
    struct PaneCapture {
        var tabID: String
        var paneID: String
        var rows: [[TerminalScreenCell]]
        var defaultStyle: TerminalTextStyle

        init(
            tabID: String,
            paneID: String,
            rows: [[TerminalScreenCell]],
            defaultStyle: TerminalTextStyle = .default
        ) {
            self.tabID = tabID
            self.paneID = paneID
            self.rows = rows
            self.defaultStyle = defaultStyle
        }

        init(
            tabID: String,
            paneID: String,
            scrollback: BoundedScrollbackRows,
            defaultStyle: TerminalTextStyle = .default
        ) {
            self.init(
                tabID: tabID,
                paneID: paneID,
                rows: (0..<scrollback.count).compactMap { scrollback.row(at: $0) },
                defaultStyle: defaultStyle
            )
        }
    }

    private let store: TerminalScrollbackSnapshotStore
    private let writer: TerminalScrollbackSnapshotWriter
    /// Mirror of `terminal.restoreScrollbackOnLaunch`. Capture keeps running
    /// when restore is disabled would be wasted work, so the flag gates both.
    private let isEnabled: Bool

    init(
        store: TerminalScrollbackSnapshotStore,
        writer: TerminalScrollbackSnapshotWriter? = nil,
        isEnabled: Bool = TerminalScrollbackRestoreSetting.defaultValue
    ) {
        self.store = store
        self.writer = writer ?? TerminalScrollbackSnapshotWriter(store: store)
        self.isEnabled = isEnabled
    }

    /// Convenience for the app: returns `nil` when Application Support is
    /// unavailable rather than inventing a fallback path.
    static func makeDefault(
        isEnabled: Bool = TerminalScrollbackRestoreSetting.defaultValue
    ) -> TerminalScrollbackSnapshotCoordinator? {
        guard let rootURL = TerminalScrollbackSnapshotStore.defaultRootURL() else {
            return nil
        }
        return TerminalScrollbackSnapshotCoordinator(
            store: TerminalScrollbackSnapshotStore(rootURL: rootURL),
            isEnabled: isEnabled
        )
    }

    /// Serializes and enqueues one pane's snapshot, returning the reference to
    /// record in the workspace snapshot. `nil` means nothing was persisted.
    @discardableResult
    func capture(_ capture: PaneCapture) -> String? {
        guard isEnabled else {
            return nil
        }
        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: capture.rows,
            defaultStyle: capture.defaultStyle
        )
        let ref = TerminalScrollbackSnapshotFormat.ref(tabID: capture.tabID, paneID: capture.paneID)
        guard !payload.isEmpty else {
            writer.write(ref: ref, payload: Data())
            return nil
        }
        writer.write(ref: ref, payload: payload)
        return ref
    }

    /// Replays one pane's stored bytes for display. Never writes to the PTY and
    /// never runs a command; `WorkspaceCommandReplayCandidate` remains the only
    /// path that can do that, behind its own explicit opt-in.
    @discardableResult
    func restore(
        candidate: WorkspaceScrollbackReplayCandidate,
        into target: TerminalScrollbackReplayTarget
    ) -> TerminalScrollbackReplayReport {
        guard isEnabled else {
            return .skipped
        }
        return TerminalScrollbackReplayer.replay(
            ref: candidate.scrollbackRef,
            from: store,
            into: target
        )
    }

    /// Drops snapshots for panes the workspace no longer contains and enforces
    /// the total directory budget.
    func prune(retaining snapshot: WorkspaceSnapshot) {
        writer.prune(keepingRefs: snapshot.scrollbackSnapshotRefs)
    }

    /// Blocks until enqueued writes land. Called from app termination so a quit
    /// cannot race the last snapshot.
    func flushPendingWrites() {
        writer.waitForPendingWork()
    }
}
