import AppKit

/// Sidebar split behavior for the terminal window: drag-to-resize for the
/// command-history (left) and file-explorer (right) panes.
///
/// A `.thin` divider is only a hairline wide, which is far too small a target
/// to grab reliably, so `effectiveRect` widens the hit area without changing
/// how the divider draws. Min/max positions are enforced here rather than by
/// constraints alone: an autolayout `NSSplitView` clamps the drag itself, and
/// leaving it to low-priority width constraints makes the divider feel like it
/// sticks at the limits instead of stopping cleanly.
extension TerminalWindowController: NSSplitViewDelegate {
    private var sidebarSplitPanes: [NSView] {
        commandHistorySplitView.arrangedSubviews
    }

    /// Which sidebar a divider belongs to.
    ///
    /// Panes are added and removed as the sidebars toggle, so a divider's index
    /// says nothing about which one it is: with the history panel hidden the
    /// explorer's divider *is* divider 0. Reading the index as "0 means left"
    /// clamped the explorer's divider to the history panel's limits, which is
    /// how the explorer ended up owning everything right of 460pt.
    private enum SidebarDivider {
        case history
        case explorer
        case other
    }

    private func sidebarDivider(at dividerIndex: Int) -> SidebarDivider {
        let panes = sidebarSplitPanes
        guard dividerIndex >= 0, dividerIndex + 1 < panes.count else {
            return .other
        }
        if panes[dividerIndex] === leftSidebarPanel {
            return .history
        }
        if panes[dividerIndex + 1] === fileExplorerPanel {
            return .explorer
        }
        return .other
    }

    /// A divider's position is the trailing edge of the pane before it, so the
    /// explorer gets whatever is left once the divider itself is subtracted.
    private func explorerDividerPosition(forWidth explorerWidth: CGFloat) -> CGFloat {
        commandHistorySplitView.bounds.width
            - explorerWidth
            - commandHistorySplitView.dividerThickness
    }

    /// Where the terminal column starts, so the explorer's divider knows how
    /// much room is left for it. Zero when the history panel is hidden.
    private var terminalColumnLeadingEdge: CGFloat {
        terminalContentHostView.frame.minX
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === commandHistorySplitView else {
            return proposedMinimumPosition
        }
        switch sidebarDivider(at: dividerIndex) {
        case .history:
            // Position is the history panel's trailing edge.
            return DesignTokens.Component.commandHistoryPanelMinWidthPX
        case .explorer:
            // Keep the explorer no wider than its maximum, which means the
            // divider cannot move further left than that — and no further left
            // than leaves the terminal its own floor. On a window too narrow to
            // satisfy both, the explorer's minimum still wins, matching how
            // `resizeSubviewsWithOldSize` refuses to take a sidebar below it.
            let widest = explorerDividerPosition(
                forWidth: DesignTokens.Component.fileExplorerPanelMaxWidthPX
            )
            let terminalFloor = terminalColumnLeadingEdge
                + DesignTokens.Component.terminalColumnMinWidthPX
            let narrowest = explorerDividerPosition(
                forWidth: DesignTokens.Component.fileExplorerPanelMinWidthPX
            )
            return min(max(widest, terminalFloor), narrowest)
        case .other:
            return proposedMinimumPosition
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === commandHistorySplitView else {
            return proposedMaximumPosition
        }
        switch sidebarDivider(at: dividerIndex) {
        case .history:
            return DesignTokens.Component.commandHistoryPanelMaxWidthPX
        case .explorer:
            return explorerDividerPosition(
                forWidth: DesignTokens.Component.fileExplorerPanelMinWidthPX
            )
        case .other:
            return proposedMaximumPosition
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        guard splitView === commandHistorySplitView else {
            return proposedEffectiveRect
        }
        let grabPadding = DesignTokens.Component.sidebarDividerGrabPaddingPX
        return drawnRect.insetBy(dx: -grabPadding, dy: 0)
    }

    /// Only the terminal column may absorb window resizing; the sidebars keep
    /// the width the user dragged them to.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard splitView === commandHistorySplitView else {
            return true
        }
        return view === terminalContentHostView
    }

    /// Panels are shown and hidden through the toggles, so double-clicking the
    /// divider must not collapse them into an unreachable state.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    /// Shows or hides one sidebar pane.
    ///
    /// Hiding is done by removing the pane from the split view entirely rather
    /// than by `isHidden`. A split view draws one divider per gap between its
    /// arranged subviews and owns their geometry through divider positions, so
    /// a merely hidden pane kept its last frame and left a divider hairline and
    /// an empty strip at the window edge. With the pane removed there is no gap
    /// to draw and no frame to keep; showing re-inserts it at its edge and
    /// re-applies the width constraints and holding priorities.
    func setSidebarPanelHidden(_ hidden: Bool, panel: NSView) {
        let splitView = commandHistorySplitView
        panel.isHidden = hidden
        if hidden {
            guard splitView.arrangedSubviews.contains(panel) else {
                return
            }
            splitView.removeArrangedSubview(panel)
            panel.removeFromSuperview()
        } else {
            guard !splitView.arrangedSubviews.contains(panel) else {
                return
            }
            // The history panel is always the leading pane and the explorer the
            // trailing one; the terminal host stays in the middle.
            if panel === leftSidebarPanel {
                splitView.insertArrangedSubview(panel, at: 0)
            } else {
                splitView.addArrangedSubview(panel)
            }
        }
        applySidebarHoldingPriorities()
        splitView.adjustSubviews()
        if !hidden {
            // `adjustSubviews` gives a freshly inserted column whatever is
            // left over, which is the whole window when it is the only sidebar.
            // Put the divider at the panel's default width instead.
            openSidebarPanelAtDefaultWidth(panel)
        }
        splitView.needsLayout = true
        splitView.needsDisplay = true
    }

    /// Places a newly revealed panel at its designed width.
    private func openSidebarPanelAtDefaultWidth(_ panel: NSView) {
        let splitView = commandHistorySplitView
        guard splitView.arrangedSubviews.contains(panel) else {
            return
        }
        if panel === leftSidebarPanel {
            splitView.setPosition(
                DesignTokens.Component.commandHistoryPanelDefaultWidthPX,
                ofDividerAt: 0
            )
            return
        }
        let dividerIndex = max(0, splitView.arrangedSubviews.count - 2)
        splitView.setPosition(
            explorerDividerPosition(forWidth: DesignTokens.Component.fileExplorerPanelDefaultWidthPX),
            ofDividerAt: dividerIndex
        )
    }

    /// Distributes width across the columns on every resize.
    ///
    /// The default distribution lets the terminal absorb everything, which is
    /// right until the window gets small: the terminal reaches zero while two
    /// sidebars sit at 400pt each, and the window is left with no terminal in
    /// it. So the terminal keeps a floor, and the sidebars give width back —
    /// widest first, never below their own minimums — until it is met.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // `adjustSubviews()` routes straight back into this method, so the
        // layout has to be done here for every case, including the trivial ones.
        let panes = splitView.arrangedSubviews
        guard splitView === commandHistorySplitView, panes.count > 1,
              let terminalIndex = panes.firstIndex(of: terminalContentHostView)
        else {
            fillEvenly(panes, in: splitView)
            return
        }

        let dividerTotal = splitView.dividerThickness * CGFloat(panes.count - 1)
        let available = max(0, splitView.bounds.width - dividerTotal)
        var widths = panes.map { pane -> CGFloat in
            pane === terminalContentHostView
                ? 0
                : min(max(pane.frame.width, sidebarMinimumWidth(at: panes.firstIndex(of: pane) ?? 0, in: panes)),
                      sidebarMaximumWidth(at: panes.firstIndex(of: pane) ?? 0, in: panes))
        }
        widths[terminalIndex] = available - widths.enumerated()
            .filter { $0.offset != terminalIndex }
            .reduce(0) { $0 + $1.element }

        var deficit = DesignTokens.Component.terminalColumnMinWidthPX - widths[terminalIndex]
        while deficit > 0 {
            // Widest sidebar first, so one very wide panel gives before a panel
            // already near its floor does.
            let donors = widths.enumerated()
                .filter { $0.offset != terminalIndex }
                .filter { $0.element > sidebarMinimumWidth(at: $0.offset, in: panes) }
                .sorted { $0.element > $1.element }
            guard let donor = donors.first else {
                break
            }
            let floor = sidebarMinimumWidth(at: donor.offset, in: panes)
            let take = min(deficit, donor.element - floor)
            widths[donor.offset] -= take
            widths[terminalIndex] += take
            deficit -= take
        }

        var x: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            pane.frame = NSRect(
                x: x,
                y: 0,
                width: max(0, widths[index]),
                height: splitView.bounds.height
            )
            x += max(0, widths[index]) + splitView.dividerThickness
        }
    }

    /// Fallback for the cases the sidebar rule does not apply to: one column,
    /// or a split view this controller does not own. Keeps the existing
    /// proportions rather than inventing a distribution.
    private func fillEvenly(_ panes: [NSView], in splitView: NSSplitView) {
        guard !panes.isEmpty else { return }
        let dividerTotal = splitView.dividerThickness * CGFloat(panes.count - 1)
        let available = max(0, splitView.bounds.width - dividerTotal)
        let previousTotal = panes.reduce(0) { $0 + $1.frame.width }
        var x: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let share = previousTotal > 0
                ? available * (pane.frame.width / previousTotal)
                : available / CGFloat(panes.count)
            let width = index == panes.count - 1 ? max(0, available - x) : share
            pane.frame = NSRect(x: x, y: 0, width: width, height: splitView.bounds.height)
            x += width + splitView.dividerThickness
        }
    }

    private func sidebarMinimumWidth(at index: Int, in panes: [NSView]) -> CGFloat {
        panes[index] === leftSidebarPanel
            ? DesignTokens.Component.commandHistoryPanelMinWidthPX
            : DesignTokens.Component.fileExplorerPanelMinWidthPX
    }

    private func sidebarMaximumWidth(at index: Int, in panes: [NSView]) -> CGFloat {
        panes[index] === leftSidebarPanel
            ? DesignTokens.Component.commandHistoryPanelMaxWidthPX
            : DesignTokens.Component.fileExplorerPanelMaxWidthPX
    }

    /// Only the terminal host should absorb leftover width, so every sidebar
    /// pane holds its size. Indices shift as panes are added and removed, so
    /// this is re-applied on every visibility change.
    private func applySidebarHoldingPriorities() {
        for (index, subview) in commandHistorySplitView.arrangedSubviews.enumerated() {
            commandHistorySplitView.setHoldingPriority(
                subview === terminalContentHostView ? .defaultLow : .defaultHigh,
                forSubviewAt: index
            )
        }
    }

    /// The split view's autosaved frames remember a pane that was hidden as
    /// zero-width, so a freshly shown panel can come back with no width at all.
    /// Push the divider back out to the panel's default width in that case.
    func restoreSidebarWidthIfCollapsed(_ panel: NSView) {
        let splitView = commandHistorySplitView
        guard splitView.arrangedSubviews.contains(panel) else {
            return
        }
        let isLeading = panel === leftSidebarPanel
        let minimumWidth = isLeading
            ? DesignTokens.Component.commandHistoryPanelMinWidthPX
            : DesignTokens.Component.fileExplorerPanelMinWidthPX
        guard panel.frame.width < minimumWidth else {
            return
        }
        let defaultWidth = isLeading
            ? DesignTokens.Component.commandHistoryPanelDefaultWidthPX
            : DesignTokens.Component.fileExplorerPanelDefaultWidthPX
        if isLeading {
            splitView.setPosition(defaultWidth, ofDividerAt: 0)
        } else {
            let dividerIndex = max(0, splitView.arrangedSubviews.count - 2)
            splitView.setPosition(
                explorerDividerPosition(forWidth: defaultWidth),
                ofDividerAt: dividerIndex
            )
        }
    }
}
