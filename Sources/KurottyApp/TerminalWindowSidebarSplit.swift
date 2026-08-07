import AppKit

/// Sidebar split behavior for the terminal window: drag-to-resize for the
/// file-explorer and command-history panes.
///
/// A `.thin` divider is only a hairline wide, which is far too small a target
/// to grab reliably, so `effectiveRect` widens the hit area without changing
/// how the divider draws. Min/max positions are enforced here rather than by
/// constraints alone: an autolayout `NSSplitView` clamps the drag itself, and
/// leaving it to low-priority width constraints makes the divider feel like it
/// sticks at the limits instead of stopping cleanly.
///
/// Nothing below names a side except `sidebarColumnOrder`. Which pane is
/// leading is one array; every limit, divider lookup, insertion point, and
/// default-width restore reads its side from that array rather than repeating
/// the arrangement. That is the whole reason the swap was a one-line change,
/// and it is what keeps a future re-ordering from being another audit of this
/// file.
extension TerminalWindowController: NSSplitViewDelegate {
    /// Which sidebar a pane or a divider belongs to.
    ///
    /// Named by *content*, never by side. Panes are added and removed as the
    /// sidebars toggle, so a divider's index says nothing about which one it
    /// is: with one panel hidden the other's divider *is* divider 0. Reading
    /// the index as "0 means left" clamped one sidebar to the other's limits,
    /// which is how the explorer ended up owning everything right of 460pt.
    enum SidebarColumn: CaseIterable {
        case explorer
        case history
    }

    /// The sidebar columns in window order, leading to trailing, with the
    /// terminal between them.
    ///
    /// The explorer leads because it is the panel that is read constantly and
    /// the history panel is the one consulted occasionally; the frequently used
    /// tree belongs on the side the eye already returns to. Reversing this
    /// array is the entire swap.
    static let sidebarColumnOrder: [SidebarColumn] = [.explorer, .history]

    /// Widths for one column. Grouped so a limit can never be read from the
    /// wrong pane's token by picking the wrong branch of a ternary.
    struct SidebarColumnWidths {
        let minimumPX: CGFloat
        let defaultPX: CGFloat
        let maximumPX: CGFloat
    }

    static func sidebarColumnWidths(for column: SidebarColumn) -> SidebarColumnWidths {
        switch column {
        case .explorer:
            return SidebarColumnWidths(
                minimumPX: DesignTokens.Component.fileExplorerPanelMinWidthPX,
                defaultPX: DesignTokens.Component.fileExplorerPanelDefaultWidthPX,
                maximumPX: DesignTokens.Component.fileExplorerPanelMaxWidthPX
            )
        case .history:
            return SidebarColumnWidths(
                minimumPX: DesignTokens.Component.commandHistoryPanelMinWidthPX,
                defaultPX: DesignTokens.Component.commandHistoryPanelDefaultWidthPX,
                maximumPX: DesignTokens.Component.commandHistoryPanelMaxWidthPX
            )
        }
    }

    /// `true` when the column sits before the terminal.
    static func isLeadingSidebarColumn(_ column: SidebarColumn) -> Bool {
        sidebarColumnOrder.first == column
    }

    /// The panel view that hosts a column.
    func sidebarPanel(for column: SidebarColumn) -> NSView {
        switch column {
        case .explorer:
            return fileExplorerPanel
        case .history:
            return leftSidebarPanel
        }
    }

    /// The column a panel hosts, or `nil` for the terminal host and anything
    /// else that is not a sidebar.
    func sidebarColumn(for panel: NSView) -> SidebarColumn? {
        SidebarColumn.allCases.first { sidebarPanel(for: $0) === panel }
    }

    private var sidebarSplitPanes: [NSView] {
        commandHistorySplitView.arrangedSubviews
    }

    /// Which sidebar owns a divider, resolved by pane identity.
    ///
    /// A leading sidebar owns the divider immediately *after* it; a trailing
    /// sidebar owns the divider immediately *before* it. The terminal sits
    /// between the two, so no divider can satisfy both tests.
    private func sidebarDivider(at dividerIndex: Int) -> SidebarColumn? {
        let panes = sidebarSplitPanes
        guard dividerIndex >= 0, dividerIndex + 1 < panes.count else {
            return nil
        }
        if let column = sidebarColumn(for: panes[dividerIndex]),
           Self.isLeadingSidebarColumn(column) {
            return column
        }
        if let column = sidebarColumn(for: panes[dividerIndex + 1]),
           !Self.isLeadingSidebarColumn(column) {
            return column
        }
        return nil
    }

    /// The divider index a column's divider currently sits at, or `nil` when
    /// the column is hidden.
    private func dividerIndex(for column: SidebarColumn) -> Int? {
        let panes = sidebarSplitPanes
        guard let paneIndex = panes.firstIndex(of: sidebarPanel(for: column)) else {
            return nil
        }
        let index = Self.isLeadingSidebarColumn(column) ? paneIndex : paneIndex - 1
        guard index >= 0, index + 1 < panes.count else {
            return nil
        }
        return index
    }

    /// A divider's position is the trailing edge of the pane before it, so a
    /// *trailing* column gets whatever is left once the divider is subtracted.
    /// A leading column's divider position is simply its own width.
    private func dividerPosition(for column: SidebarColumn, width: CGFloat) -> CGFloat {
        guard !Self.isLeadingSidebarColumn(column) else {
            return width
        }
        return commandHistorySplitView.bounds.width
            - width
            - commandHistorySplitView.dividerThickness
    }

    /// Where the terminal column starts, so a trailing sidebar's divider knows
    /// how much room is left for it.
    private var terminalColumnLeadingEdge: CGFloat {
        terminalContentHostView.frame.minX
    }

    /// Where the terminal column ends, so a leading sidebar's divider knows how
    /// far it may travel. This is the trailing sidebar's divider when that
    /// panel is shown and the split view's trailing edge when it is not.
    private var terminalColumnTrailingEdge: CGFloat {
        terminalContentHostView.frame.maxX
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === commandHistorySplitView,
              let column = sidebarDivider(at: dividerIndex)
        else {
            return proposedMinimumPosition
        }
        let widths = Self.sidebarColumnWidths(for: column)
        guard !Self.isLeadingSidebarColumn(column) else {
            // Position is the leading panel's own trailing edge.
            return widths.minimumPX
        }
        // A trailing panel grows leftwards, so its maximum is this divider's
        // *minimum* position — and it may not move further left than leaves the
        // terminal its own floor. On a window too narrow to satisfy both, the
        // panel's minimum still wins, matching how `resizeSubviewsWithOldSize`
        // refuses to take a sidebar below it.
        let widest = dividerPosition(for: column, width: widths.maximumPX)
        let terminalFloor = terminalColumnLeadingEdge
            + DesignTokens.Component.terminalColumnMinWidthPX
        let narrowest = dividerPosition(for: column, width: widths.minimumPX)
        return min(max(widest, terminalFloor), narrowest)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === commandHistorySplitView,
              let column = sidebarDivider(at: dividerIndex)
        else {
            return proposedMaximumPosition
        }
        let widths = Self.sidebarColumnWidths(for: column)
        guard Self.isLeadingSidebarColumn(column) else {
            return dividerPosition(for: column, width: widths.minimumPX)
        }
        // The trailing panel's divider already refuses to squeeze the terminal;
        // the leading one did not, so dragging it to its maximum took the
        // terminal below its floor -- 88pt in a 760pt window, and still only
        // 130pt at 900pt, against a 240pt minimum. The terminal sits between the
        // two dividers, so this one's ceiling is the terminal's trailing edge
        // less its floor and the divider itself.
        let widest = widths.maximumPX
        let terminalCeiling = terminalColumnTrailingEdge
            - DesignTokens.Component.terminalColumnMinWidthPX
            - commandHistorySplitView.dividerThickness
        // On a window too narrow to satisfy both, the panel's own minimum wins,
        // the same order the trailing case uses.
        return max(min(widest, terminalCeiling), widths.minimumPX)
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
            // The terminal host stays in the middle, so a leading column goes in
            // front of everything and a trailing one behind it.
            let isLeading = sidebarColumn(for: panel).map(Self.isLeadingSidebarColumn) ?? false
            if isLeading {
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
        rebalanceSidebarColumns()
        splitView.needsLayout = true
        splitView.needsDisplay = true
    }

    /// Re-runs the column distribution against the split view's current width.
    ///
    /// The terminal's floor lived only in `resizeSubviewsWithOldSize`, and
    /// AppKit calls that when the split view's *size* changes — not when a
    /// divider moves and not when a pane is inserted. `setPosition` writes
    /// frames straight through, and `adjustSubviews()` is the default
    /// distribution that deliberately bypasses the delegate, so neither one
    /// re-ran the rule. The floor was therefore enforced on window resize and
    /// nowhere else: opening both sidebars in a 760pt window left the terminal
    /// at 208pt against its 240pt minimum and nothing ever took it back. It
    /// only looked correct while the panel that could give was also the panel
    /// whose own divider constraint happened to be doing the arithmetic.
    private func rebalanceSidebarColumns() {
        guard commandHistorySplitView.bounds.width > 0 else {
            return
        }
        splitView(
            commandHistorySplitView,
            resizeSubviewsWithOldSize: commandHistorySplitView.bounds.size
        )
    }

    /// Places a newly revealed panel at its designed width.
    private func openSidebarPanelAtDefaultWidth(_ panel: NSView) {
        guard commandHistorySplitView.arrangedSubviews.contains(panel),
              let column = sidebarColumn(for: panel),
              let dividerIndex = dividerIndex(for: column)
        else {
            return
        }
        commandHistorySplitView.setPosition(
            dividerPosition(for: column, width: Self.sidebarColumnWidths(for: column).defaultPX),
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
        var widths = panes.enumerated().map { index, pane -> CGFloat in
            pane === terminalContentHostView
                ? 0
                : min(max(pane.frame.width, sidebarMinimumWidth(at: index, in: panes)),
                      sidebarMaximumWidth(at: index, in: panes))
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

    /// Floors and ceilings by pane identity. The terminal host is not a sidebar
    /// and answers to its own floor; returning a sidebar's limit for it was how
    /// "anything that is not the left panel is the explorer" survived this file.
    private func sidebarMinimumWidth(at index: Int, in panes: [NSView]) -> CGFloat {
        guard let column = sidebarColumn(for: panes[index]) else {
            return DesignTokens.Component.terminalColumnMinWidthPX
        }
        return Self.sidebarColumnWidths(for: column).minimumPX
    }

    private func sidebarMaximumWidth(at index: Int, in panes: [NSView]) -> CGFloat {
        guard let column = sidebarColumn(for: panes[index]) else {
            return .greatestFiniteMagnitude
        }
        return Self.sidebarColumnWidths(for: column).maximumPX
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
    ///
    /// The autosave name is versioned (`AppConstants.CommandHistory
    /// .splitViewAutosaveName`) precisely so this never has to reason about a
    /// width recorded for a different arrangement: swapping the sides bumped the
    /// version, so the frames this reads are always frames of the current order.
    func restoreSidebarWidthIfCollapsed(_ panel: NSView) {
        guard commandHistorySplitView.arrangedSubviews.contains(panel),
              let column = sidebarColumn(for: panel),
              let dividerIndex = dividerIndex(for: column)
        else {
            return
        }
        let widths = Self.sidebarColumnWidths(for: column)
        guard panel.frame.width < widths.minimumPX else {
            return
        }
        commandHistorySplitView.setPosition(
            dividerPosition(for: column, width: widths.defaultPX),
            ofDividerAt: dividerIndex
        )
        rebalanceSidebarColumns()
    }
}
