import AppKit

/// Directional pane-focus navigation for `SplitTerminalView`: geometric
/// nearest-neighbor selection over the pane tree. Extracted verbatim from
/// `SplitTerminalView.swift`.
extension SplitTerminalView {
    fileprivate struct PaneFocusCandidate {
        let pane: TerminalPaneView
        let rect: NSRect
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
}
