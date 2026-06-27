import AppKit

final class SplitTerminalView: NSSplitView {
    init(axis: NSLayoutConstraint.Orientation, pane: TerminalPaneView = TerminalPaneView()) {
        super.init(frame: .zero)
        isVertical = axis == .vertical
        dividerStyle = .paneSplitter
        configurePane(pane)
        addArrangedSubview(pane)
        refreshPaneChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func split(axis: NSLayoutConstraint.Orientation) {
        if !splitActivePane(axis: axis) {
            splitFallback(axis: axis)
        }
        rebalanceDividers()
        refreshPaneChrome()
    }

    func focusFirstPane() {
        firstPane()?.focusTerminal()
    }

    var primaryTerminalSurface: TerminalSurfaceView? {
        firstPane()?.terminalSurface
    }

    func containsTerminalSurface(_ surface: TerminalSurfaceView) -> Bool {
        for subview in arrangedSubviews {
            if let pane = subview as? TerminalPaneView,
               pane.terminalSurface === surface {
                return true
            }
            if let splitView = subview as? SplitTerminalView,
               splitView.containsTerminalSurface(surface) {
                return true
            }
        }
        return false
    }

    func closeActivePane() -> Bool {
        guard paneCount > 1 else {
            return false
        }
        guard let pane = activePane() else {
            return false
        }
        remove(pane)
        refreshPaneChrome()
        return true
    }

    private func splitActivePane(axis: NSLayoutConstraint.Orientation) -> Bool {
        for subview in arrangedSubviews {
            if let pane = subview as? TerminalPaneView, pane.ownsFirstResponder {
                split(pane, axis: axis)
                return true
            }
            if let splitView = subview as? SplitTerminalView,
               splitView.splitActivePane(axis: axis) {
                splitView.rebalanceDividers()
                return true
            }
        }
        return false
    }

    private func split(_ pane: TerminalPaneView, axis: NSLayoutConstraint.Orientation) {
        let newPane = TerminalPaneView()
        configurePane(newPane)
        if isVertical == (axis == .vertical),
           let paneIndex = arrangedSubviews.firstIndex(of: pane) {
            insertArrangedSubview(newPane, at: paneIndex + 1)
        } else {
            replace(pane, withNestedSplitFor: axis, newPane: newPane)
        }
        newPane.focusTerminal()
        rebalanceDividers()
    }

    private func replace(
        _ pane: TerminalPaneView,
        withNestedSplitFor axis: NSLayoutConstraint.Orientation,
        newPane: TerminalPaneView
    ) {
        guard let paneIndex = arrangedSubviews.firstIndex(of: pane) else {
            return
        }
        removeArrangedSubview(pane)
        pane.removeFromSuperview()

        let nestedSplit = SplitTerminalView(axis: axis, pane: pane)
        configurePane(newPane)
        nestedSplit.addArrangedSubview(newPane)
        insertArrangedSubview(nestedSplit, at: paneIndex)
        nestedSplit.refreshPaneChrome()
    }

    private func splitFallback(axis: NSLayoutConstraint.Orientation) {
        let newPane = TerminalPaneView()
        configurePane(newPane)
        if arrangedSubviews.isEmpty || isVertical == (axis == .vertical) {
            addArrangedSubview(newPane)
        } else if let pane = arrangedSubviews.first as? TerminalPaneView {
            replace(pane, withNestedSplitFor: axis, newPane: newPane)
        } else {
            addArrangedSubview(newPane)
        }
        newPane.focusTerminal()
        rebalanceDividers()
    }

    private func configurePane(_ pane: TerminalPaneView) {
        pane.closeRequested = { [weak self] pane in
            guard let self else {
                return
            }
            guard self.paneCount > 1 else {
                return
            }
            self.remove(pane)
            self.refreshPaneChrome()
            self.focusFirstPane()
        }
        pane.focusChanged = { [weak self] _ in
            self?.refreshPaneChrome()
        }
    }

    private func refreshPaneChrome() {
        let showChrome = paneCount > 1
        applyPaneChrome(isVisible: showChrome)
    }

    private func applyPaneChrome(isVisible: Bool) {
        for subview in arrangedSubviews {
            if let pane = subview as? TerminalPaneView {
                pane.setChromeVisible(isVisible)
                pane.setChromeActive(pane.ownsFirstResponder)
            } else if let splitView = subview as? SplitTerminalView {
                splitView.applyPaneChrome(isVisible: isVisible)
            }
        }
    }

    private func activePane() -> TerminalPaneView? {
        for subview in arrangedSubviews {
            if let pane = subview as? TerminalPaneView, pane.ownsFirstResponder {
                return pane
            }
            if let splitView = subview as? SplitTerminalView,
               let pane = splitView.activePane() {
                return pane
            }
        }
        return nil
    }

    private func firstPane() -> TerminalPaneView? {
        for subview in arrangedSubviews {
            if let pane = subview as? TerminalPaneView {
                return pane
            }
            if let splitView = subview as? SplitTerminalView,
               let pane = splitView.firstPane() {
                return pane
            }
        }
        return nil
    }

    private var paneCount: Int {
        arrangedSubviews.reduce(0) { count, subview in
            if subview is TerminalPaneView {
                return count + 1
            }
            if let splitView = subview as? SplitTerminalView {
                return count + splitView.paneCount
            }
            return count
        }
    }

    private func remove(_ pane: TerminalPaneView) {
        for subview in arrangedSubviews {
            if subview === pane {
                removeArrangedSubview(pane)
                pane.removeFromSuperview()
                return
            }
            if let splitView = subview as? SplitTerminalView {
                splitView.remove(pane)
                splitView.rebalanceDividers()
            }
        }
        rebalanceDividers()
    }

    private func rebalanceDividers() {
        layoutSubtreeIfNeeded()
        adjustSubviews()
        let count = arrangedSubviews.count
        guard count > 1 else {
            return
        }
        let totalLength = isVertical ? bounds.width : bounds.height
        guard totalLength > 0 else {
            return
        }
        for dividerIndex in 0..<(count - 1) {
            let position = totalLength * CGFloat(dividerIndex + 1) / CGFloat(count)
            setPosition(position, ofDividerAt: dividerIndex)
        }
    }
}
