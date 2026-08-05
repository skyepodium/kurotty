import AppKit

/// Window-level call sites for scrollback persistence: capture on save/quit,
/// display-only replay on restore, and pruning of snapshots no live pane
/// references.
///
/// Safety contract: nothing here writes to a PTY. A restored pane receives
/// bytes through `TerminalScrollbackReplayTarget` with the replay flag raised,
/// so a capability query recorded in a previous process can never be answered
/// into the freshly launched shell. Replaying a *command* remains a separate
/// opt-in on `TerminalRestoreSafetyMetadata`, and this file never touches it.
extension TerminalWindowController {
    /// Serializes one pane's trailing rows and enqueues the write, returning the
    /// reference to record in the workspace snapshot.
    func captureScrollbackSnapshot(
        of pane: TerminalPaneView,
        tabID: String,
        paneID: String
    ) -> String? {
        guard let scrollbackSnapshotCoordinator else {
            return nil
        }
        let surface = pane.terminalSurface
        return scrollbackSnapshotCoordinator.capture(
            TerminalScrollbackSnapshotCoordinator.PaneCapture(
                tabID: tabID,
                paneID: paneID,
                rows: surface.persistableScrollbackRows(),
                defaultStyle: surface.persistableDefaultStyle
            )
        )
    }

    /// Live panes keyed by the identifier the workspace descriptor assigns them.
    /// Built through the same traversal as the descriptor so restore can never
    /// pair a snapshot with a different slot than the one it was captured from.
    func panesByLayoutIdentifier() -> [String: TerminalPaneView] {
        var panes: [String: TerminalPaneView] = [:]
        for index in 0..<tabView.numberOfTabViewItems {
            guard let splitView = tabView.tabViewItem(at: index).view as? SplitTerminalView else {
                continue
            }
            _ = splitView.layoutOnlyDescriptor(
                idPrefix: layoutIDPrefix(forTabIndex: index)
            ) { pane, paneID in
                panes[paneID] = pane
                return nil
            }
        }
        return panes
    }

    /// Feeds each stored snapshot back into the pane that occupies the same
    /// layout slot. Returns one report per replayed pane for diagnostics and
    /// tests; a candidate with no matching live pane is skipped.
    @discardableResult
    func restoreScrollback(
        from snapshot: WorkspaceSnapshot
    ) -> [String: TerminalScrollbackReplayReport] {
        guard let scrollbackSnapshotCoordinator else {
            return [:]
        }
        let panes = panesByLayoutIdentifier()
        var reports: [String: TerminalScrollbackReplayReport] = [:]
        for candidate in snapshot.restorePlan.scrollbackReplayCandidates {
            guard let pane = panes[candidate.paneID.rawValue] else {
                continue
            }
            reports[candidate.paneID.rawValue] = scrollbackSnapshotCoordinator.restore(
                candidate: candidate,
                into: pane.terminalSurface
            )
        }
        return reports
    }

    /// Drops snapshots for panes the workspace no longer contains and enforces
    /// the total directory budget.
    func pruneScrollbackSnapshots(retaining snapshot: WorkspaceSnapshot) {
        scrollbackSnapshotCoordinator?.prune(retaining: snapshot)
    }

    /// Blocks until enqueued snapshot writes land. Called from termination so a
    /// quit cannot race the debounced write queue.
    func flushScrollbackSnapshotWrites() {
        scrollbackSnapshotCoordinator?.flushPendingWrites()
    }
}
