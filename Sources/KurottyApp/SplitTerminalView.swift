import AppKit

final class SplitTerminalView: NSSplitView {
    private struct PaneFocusCandidate {
        let pane: TerminalPaneView
        let rect: NSRect
    }

    private var needsInitialRebalance = false
    private let paneDragCoordinator: TerminalPaneDragCoordinator

    override var dividerThickness: CGFloat {
        DesignTokens.Component.terminalSplitDividerHitAreaPX
    }

    init(
        axis: NSLayoutConstraint.Orientation,
        pane: TerminalPaneView? = TerminalPaneView(),
        paneDragCoordinator: TerminalPaneDragCoordinator
    ) {
        self.paneDragCoordinator = paneDragCoordinator
        super.init(frame: .zero)
        isVertical = axis == .vertical
        dividerStyle = .paneSplitter
        wantsLayer = true
        layer?.backgroundColor = DesignTokens.Color.windowBackground.cgColor
        if let pane {
            configurePane(pane)
            addArrangedSubview(pane)
        }
        refreshPaneChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        if needsInitialRebalance {
            needsInitialRebalance = false
            rebalanceDividers()
        }
    }

    override func drawDivider(in rect: NSRect) {
        DesignTokens.Color.windowBackground.setFill()
        rect.fill()

        let lineThickness = DesignTokens.Component.terminalSplitDividerLinePX
        let lineRect: NSRect
        if isVertical {
            lineRect = NSRect(
                x: rect.midX - lineThickness / 2,
                y: rect.minY,
                width: lineThickness,
                height: rect.height
            )
        } else {
            lineRect = NSRect(
                x: rect.minX,
                y: rect.midY - lineThickness / 2,
                width: rect.width,
                height: lineThickness
            )
        }
        DesignTokens.Color.divider.setFill()
        lineRect.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard arrangedSubviews.count > 1 else { return }
        let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        for dividerIndex in 0..<(arrangedSubviews.count - 1) {
            addCursorRect(dividerCursorRect(at: dividerIndex), cursor: cursor)
        }
    }

    private func dividerCursorRect(at dividerIndex: Int) -> NSRect {
        guard arrangedSubviews.indices.contains(dividerIndex) else { return .zero }
        let leadingFrame = arrangedSubviews[dividerIndex].frame
        let thickness = dividerThickness
        if isVertical {
            return NSRect(
                x: leadingFrame.maxX,
                y: bounds.minY,
                width: thickness,
                height: bounds.height
            )
        }
        return NSRect(
            x: bounds.minX,
            y: leadingFrame.maxY,
            width: bounds.width,
            height: thickness
        )
    }

    func split(axis: NSLayoutConstraint.Orientation) {
        if !splitGroupAsUnit(axis: axis), !splitActivePane(axis: axis) {
            splitFallback(axis: axis)
        }
        rebalanceDividers()
        refreshPaneChrome()
    }

    func focusFirstPane() {
        firstPane()?.focusTerminal()
    }

    func focusPane(_ direction: TerminalPaneFocusDirection) {
        guard let currentPane = activePane() else {
            focusFirstPane()
            return
        }
        guard let nextPane = nearestPane(from: currentPane, direction: direction) else {
            return
        }
        nextPane.focusTerminal()
        refreshPaneChrome()
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

    func containsPane(_ pane: TerminalPaneView) -> Bool {
        for subview in arrangedSubviews {
            if subview === pane {
                return true
            }
            if let splitView = subview as? SplitTerminalView,
               splitView.containsPane(pane) {
                return true
            }
        }
        return false
    }

    func closeActivePane() -> Bool {
        guard let pane = activePane() else {
            return false
        }
        return closePaneFromChrome(pane)
    }

    func detachPaneForDrag(_ pane: TerminalPaneView) -> TerminalPaneView? {
        guard paneCount > 1 else {
            return nil
        }
        guard remove(pane) else {
            return nil
        }
        configureDetachedPaneForReuse(pane)
        refreshPaneChrome()
        focusFirstPane()
        return pane
    }

    func appendDetachedPaneAsTabRoot(_ pane: TerminalPaneView) {
        configurePane(pane)
        addArrangedSubview(pane)
        refreshPaneChrome()
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

    private func splitGroupAsUnit(axis: NSLayoutConstraint.Orientation) -> Bool {
        guard arrangedSubviews.count > 1, isVertical != (axis == .vertical) else {
            return false
        }
        guard arrangedSubviews.allSatisfy({ $0 is TerminalPaneView }) else {
            return false
        }
        guard containsActivePane() else {
            return false
        }

        let currentAxis: NSLayoutConstraint.Orientation = isVertical ? .vertical : .horizontal
        let existingGroup = SplitTerminalView(axis: currentAxis, pane: nil, paneDragCoordinator: paneDragCoordinator)
        moveCurrentArrangedSubviews(to: existingGroup)

        isVertical = axis == .vertical
        let newPane = TerminalPaneView()
        configurePane(newPane)
        addArrangedSubview(existingGroup)
        addArrangedSubview(newPane)

        // Orthogonal splits should preserve the current pane group as one unit:
        // left/right + horizontal split becomes top row with two panes, bottom row with one.
        existingGroup.needsInitialRebalance = true
        existingGroup.rebalanceDividers()
        newPane.focusTerminal()
        return true
    }

    private func moveCurrentArrangedSubviews(to existingGroup: SplitTerminalView) {
        let currentSubviews = arrangedSubviews
        for subview in currentSubviews {
            removeArrangedSubview(subview)
            subview.removeFromSuperview()
            existingGroup.addArrangedSubview(subview)
        }
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

        let nestedSplit = SplitTerminalView(axis: axis, pane: pane, paneDragCoordinator: paneDragCoordinator)
        configurePane(newPane)
        nestedSplit.addArrangedSubview(newPane)
        insertArrangedSubview(nestedSplit, at: paneIndex)
        // A nested split starts with zero or stale bounds until AppKit lays it
        // out inside the parent. Mark it for one post-layout rebalance so a
        // bottom pane split uses the bottom row's width instead of inheriting
        // a tiny default divider position.
        nestedSplit.needsInitialRebalance = true
        nestedSplit.rebalanceDividers()
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
            self.rootSplitView().closePaneFromChrome(pane)
        }
        pane.focusChanged = { [weak self] _ in
            self?.refreshPaneChrome()
        }
        pane.detachDragRequested = { [weak self] pane, event in
            guard let self else {
                return
            }
            paneDragCoordinator.beginDraggingPane(pane, from: self.rootSplitView(), with: event)
        }
    }

    private func configureDetachedPaneForReuse(_ pane: TerminalPaneView) {
        pane.closeRequested = nil
        pane.focusChanged = nil
        pane.detachDragRequested = nil
        pane.setChromeActive(false)
        pane.setChromeVisible(false)
    }

    private func rootSplitView() -> SplitTerminalView {
        var current = self
        while let parent = current.superview as? SplitTerminalView {
            current = parent
        }
        return current
    }

    @discardableResult
    private func closePaneFromChrome(_ pane: TerminalPaneView) -> Bool {
        guard paneCount > 1 else {
            return false
        }
        guard remove(pane) else {
            return false
        }
        refreshPaneChrome()
        focusFirstPane()
        return true
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

    private func containsActivePane() -> Bool {
        activePane() != nil
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

    private func nearestPane(
        from activePane: TerminalPaneView,
        direction: TerminalPaneFocusDirection
    ) -> TerminalPaneView? {
        let candidates = paneFocusCandidates()
        guard let activeCandidate = candidates.first(where: { $0.pane === activePane }) else {
            return nil
        }
        let activeRect = activeCandidate.rect
        let activeCenter = NSPoint(x: activeRect.midX, y: activeRect.midY)

        return candidates
            .filter { $0.pane !== activePane }
            .compactMap { candidate -> (pane: TerminalPaneView, score: CGFloat)? in
                let candidateCenter = NSPoint(x: candidate.rect.midX, y: candidate.rect.midY)
                let primaryDistance: CGFloat
                let perpendicularDistance: CGFloat
                let overlapsPerpendicularAxis: Bool

                switch direction {
                case .left:
                    guard candidateCenter.x < activeCenter.x else { return nil }
                    primaryDistance = activeCenter.x - candidateCenter.x
                    perpendicularDistance = abs(activeCenter.y - candidateCenter.y)
                    overlapsPerpendicularAxis = candidate.rect.maxY > activeRect.minY && candidate.rect.minY < activeRect.maxY
                case .right:
                    guard candidateCenter.x > activeCenter.x else { return nil }
                    primaryDistance = candidateCenter.x - activeCenter.x
                    perpendicularDistance = abs(activeCenter.y - candidateCenter.y)
                    overlapsPerpendicularAxis = candidate.rect.maxY > activeRect.minY && candidate.rect.minY < activeRect.maxY
                case .up:
                    // Pane navigation follows the visual terminal layout. In this
                    // view tree, converted pane rects use a top-down y ordering.
                    guard candidateCenter.y < activeCenter.y else { return nil }
                    primaryDistance = activeCenter.y - candidateCenter.y
                    perpendicularDistance = abs(activeCenter.x - candidateCenter.x)
                    overlapsPerpendicularAxis = candidate.rect.maxX > activeRect.minX && candidate.rect.minX < activeRect.maxX
                case .down:
                    guard candidateCenter.y > activeCenter.y else { return nil }
                    primaryDistance = candidateCenter.y - activeCenter.y
                    perpendicularDistance = abs(activeCenter.x - candidateCenter.x)
                    overlapsPerpendicularAxis = candidate.rect.maxX > activeRect.minX && candidate.rect.minX < activeRect.maxX
                }

                // Prefer panes that share an edge span with the current pane, then
                // choose the nearest geometric neighbor in the requested direction.
                let overlapPenalty: CGFloat = overlapsPerpendicularAxis ? 0 : 10_000
                return (candidate.pane, primaryDistance + perpendicularDistance + overlapPenalty)
            }
            .min { $0.score < $1.score }?
            .pane
    }

    private func paneFocusCandidates() -> [PaneFocusCandidate] {
        var candidates: [PaneFocusCandidate] = []
        appendPaneFocusCandidates(from: self, into: &candidates)
        return candidates
    }

    private func appendPaneFocusCandidates(from splitView: SplitTerminalView, into candidates: inout [PaneFocusCandidate]) {
        for subview in splitView.arrangedSubviews {
            if let pane = subview as? TerminalPaneView {
                let rect = pane.convert(pane.bounds, to: self)
                candidates.append(PaneFocusCandidate(pane: pane, rect: rect))
            } else if let nestedSplitView = subview as? SplitTerminalView {
                appendPaneFocusCandidates(from: nestedSplitView, into: &candidates)
            }
        }
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

    @discardableResult
    private func remove(_ pane: TerminalPaneView) -> Bool {
        for (index, subview) in arrangedSubviews.enumerated() {
            if subview === pane {
                removeArrangedSubview(pane)
                pane.removeFromSuperview()
                rebalanceDividers()
                return true
            }
            if let splitView = subview as? SplitTerminalView {
                guard splitView.remove(pane) else {
                    continue
                }
                collapseChildSplitIfNeeded(splitView, at: index)
                rebalanceDividers()
                return true
            }
        }
        return false
    }

    private func collapseChildSplitIfNeeded(_ splitView: SplitTerminalView, at index: Int) {
        if splitView.arrangedSubviews.isEmpty {
            removeArrangedSubview(splitView)
            splitView.removeFromSuperview()
            return
        }

        guard splitView.arrangedSubviews.count == 1 else {
            return
        }

        let remainingSubview = splitView.arrangedSubviews[0]
        splitView.removeArrangedSubview(remainingSubview)
        remainingSubview.removeFromSuperview()
        removeArrangedSubview(splitView)
        splitView.removeFromSuperview()
        insertArrangedSubview(remainingSubview, at: min(index, arrangedSubviews.count))
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
        // NSSplitView dividers consume layout space. Compute pane lengths from
        // the usable content span so divider hit areas do not skew visual halves.
        let dividerLength = dividerThickness * CGFloat(count - 1)
        let paneLength = (totalLength - dividerLength) / CGFloat(count)
        for dividerIndex in 0..<(count - 1) {
            let position = paneLength * CGFloat(dividerIndex + 1) + dividerThickness * CGFloat(dividerIndex)
            setPosition(position, ofDividerAt: dividerIndex)
        }
    }
}
