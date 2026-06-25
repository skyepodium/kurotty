import AppKit

final class SplitTerminalView: NSSplitView {
    init(axis: NSLayoutConstraint.Orientation, pane: TerminalPaneView = TerminalPaneView()) {
        super.init(frame: .zero)
        isVertical = axis == .vertical
        dividerStyle = .paneSplitter
        addArrangedSubview(pane)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func split(axis: NSLayoutConstraint.Orientation) {
        guard splitActivePane(axis: axis) else {
            splitFallback(axis: axis)
            return
        }
        adjustSubviews()
    }

    private func splitActivePane(axis: NSLayoutConstraint.Orientation) -> Bool {
        for subview in arrangedSubviews {
            if let pane = subview as? TerminalPaneView, pane.ownsFirstResponder {
                split(pane, axis: axis)
                return true
            }
            if let splitView = subview as? SplitTerminalView,
               splitView.splitActivePane(axis: axis) {
                splitView.adjustSubviews()
                return true
            }
        }
        return false
    }

    private func split(_ pane: TerminalPaneView, axis: NSLayoutConstraint.Orientation) {
        let newPane = TerminalPaneView()
        if isVertical == (axis == .vertical),
           let paneIndex = arrangedSubviews.firstIndex(of: pane) {
            insertArrangedSubview(newPane, at: paneIndex + 1)
        } else {
            replace(pane, withNestedSplitFor: axis, newPane: newPane)
        }
        newPane.focusTerminal()
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
        nestedSplit.addArrangedSubview(newPane)
        insertArrangedSubview(nestedSplit, at: paneIndex)
    }

    private func splitFallback(axis: NSLayoutConstraint.Orientation) {
        let newPane = TerminalPaneView()
        if arrangedSubviews.isEmpty || isVertical == (axis == .vertical) {
            addArrangedSubview(newPane)
        } else if let pane = arrangedSubviews.first as? TerminalPaneView {
            replace(pane, withNestedSplitFor: axis, newPane: newPane)
        } else {
            addArrangedSubview(newPane)
        }
        newPane.focusTerminal()
    }
}
