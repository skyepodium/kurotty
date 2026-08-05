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

    /// Shows or hides one sidebar pane.
    ///
    /// Hiding is done by removing the pane from the split view entirely rather
    /// than by `isHidden`. A split view draws one divider per gap between its
    /// arranged subviews and owns their geometry through divider positions, so
    /// a merely hidden pane kept its last frame and left a divider hairline and
    /// an empty strip at the window edge. With the pane removed there is no gap
    /// to draw and no frame to keep; showing re-inserts it at its edge and
    /// re-applies the width constraints and holding priorities.
    func setSidebarPanelHidden(
        _ hidden: Bool,
        panel: NSView,
        widthConstraints: [NSLayoutConstraint]
    ) {
        let splitView = commandHistorySplitView
        panel.isHidden = hidden
        if hidden {
            NSLayoutConstraint.deactivate(widthConstraints)
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
            // Hiding takes the panel out of the split view, which destroys the
            // constraints tying it to the split view's edges, so the height pin
            // has to be rebuilt on every reveal. Without it the panel measures
            // its own header-to-list chain and stops partway down the window
            // instead of reaching the status bar.
            NSLayoutConstraint.activate([
                panel.topAnchor.constraint(equalTo: splitView.topAnchor),
                panel.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),
            ])
            NSLayoutConstraint.activate(widthConstraints)
        }
        applySidebarHoldingPriorities()
        splitView.adjustSubviews()
        splitView.needsLayout = true
        splitView.needsDisplay = true
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
