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

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === commandHistorySplitView else {
            return proposedMinimumPosition
        }
        if dividerIndex == 0 {
            // Left divider: position is the history panel's trailing edge.
            return DesignTokens.Component.commandHistoryPanelMinWidthPX
        }
        // Right divider: keep the explorer no wider than its maximum, which
        // means the divider cannot move further left than that.
        return splitView.bounds.width - DesignTokens.Component.fileExplorerPanelMaxWidthPX
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === commandHistorySplitView else {
            return proposedMaximumPosition
        }
        if dividerIndex == 0 {
            return DesignTokens.Component.commandHistoryPanelMaxWidthPX
        }
        return splitView.bounds.width - DesignTokens.Component.fileExplorerPanelMinWidthPX
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

    /// The split view's autosaved frames remember a pane that was hidden as
    /// zero-width, so a freshly shown panel can come back with no width at all.
    /// Push the divider back out to the panel's default width in that case.
    func restoreSidebarWidthIfCollapsed(_ panel: NSView) {
        let splitView = commandHistorySplitView
        guard let index = splitView.arrangedSubviews.firstIndex(of: panel) else {
            return
        }
        let isLeading = index == 0
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
            splitView.setPosition(splitView.bounds.width - defaultWidth, ofDividerAt: dividerIndex)
        }
    }
}
