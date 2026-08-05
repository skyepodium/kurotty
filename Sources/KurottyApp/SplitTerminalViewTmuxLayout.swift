import AppKit

/// Tmux control-mode projection support for `SplitTerminalView`: the gateway
/// placeholder, tmux layout-tree installation and reconciliation, and the
/// proportion constraints that keep native splits matching the tmux layout.
/// Extracted verbatim from `SplitTerminalView.swift`.

final class TmuxGatewayPanePlaceholder: NSView {
    let layoutIdentifier = UUID().uuidString

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        layer?.backgroundColor = theme.windowBackground.cgColor
    }
}

extension SplitTerminalView {
    func replacePaneWithTmuxPlaceholder(_ pane: TerminalPaneView) -> TmuxGatewayPanePlaceholder? {
        for subview in arrangedSubviews {
            if subview === pane {
                let placeholder = TmuxGatewayPanePlaceholder(frame: pane.frame)
                placeholder.applyChromeTheme(chromeTheme)
                replaceArrangedSlot(pane, with: placeholder)
                refreshPaneChrome()
                return placeholder
            }
            if let splitView = subview as? SplitTerminalView,
               let placeholder = splitView.replacePaneWithTmuxPlaceholder(pane) {
                refreshPaneChrome()
                return placeholder
            }
        }
        return nil
    }

    @discardableResult
    func restorePane(_ pane: TerminalPaneView, replacing placeholder: TmuxGatewayPanePlaceholder) -> Bool {
        for subview in arrangedSubviews {
            if subview === placeholder {
                configurePane(pane)
                replaceArrangedSlot(placeholder, with: pane)
                refreshPaneChrome()
                return true
            }
            if let splitView = subview as? SplitTerminalView,
               splitView.restorePane(pane, replacing: placeholder) {
                refreshPaneChrome()
                return true
            }
        }
        return false
    }

    func installTmuxLayout(_ layout: TmuxLayoutNode, panes: [String: TerminalPaneView]) {
        if updateTmuxNode(layout, panes: panes, in: self) {
            refreshPaneChrome()
            applyTmuxLayoutProportionsRecursively()
            return
        }
        arrangedSubviews.forEach {
            removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        NSLayoutConstraint.deactivate(tmuxProportionConstraints)
        tmuxProportionConstraints.removeAll()
        tmuxLayoutProportions = nil
        installTmuxNode(layout, panes: panes, into: self)
        refreshPaneChrome()
        needsInitialRebalance = true
        applyTmuxLayoutProportionsRecursively()
    }

    private func updateTmuxNode(
        _ node: TmuxLayoutNode,
        panes: [String: TerminalPaneView],
        in container: SplitTerminalView
    ) -> Bool {
        switch node {
        case let .pane(id, _):
            guard container.arrangedSubviews.count == 1,
                  let pane = panes[id],
                  container.arrangedSubviews[0] === pane
            else { return false }
            container.tmuxLayoutProportions = nil
            NSLayoutConstraint.deactivate(container.tmuxProportionConstraints)
            container.tmuxProportionConstraints.removeAll()
            return true
        case let .split(axis, _, children):
            guard container.isVertical == (axis == .horizontal),
                  container.arrangedSubviews.count == children.count
            else { return false }

            for (child, subview) in zip(children, container.arrangedSubviews) {
                switch child {
                case let .pane(id, _):
                    guard let pane = panes[id], subview === pane else { return false }
                case .split:
                    guard let nested = subview as? SplitTerminalView,
                          updateTmuxNode(child, panes: panes, in: nested)
                    else { return false }
                }
            }

            let lengths = children.map { child -> CGFloat in
                switch child {
                case let .pane(_, rect), let .split(_, rect, _):
                    return CGFloat(axis == .horizontal ? rect.width : rect.height)
                }
            }
            let total = lengths.reduce(0, +)
            container.autoresizesSubviews = false
            container.tmuxLayoutProportions = total > 0 ? lengths.map { $0 / total } : nil
            container.updateTmuxProportionConstraints()
            container.needsInitialRebalance = true
            container.needsLayout = true
            return true
        }
    }

    func tmuxPaneGridSizes(in paneIDs: [String: TerminalPaneView]) -> [String: TerminalSize] {
        paneIDs.reduce(into: [:]) { result, entry in
            guard containsPane(entry.value) else { return }
            result[entry.key] = entry.value.terminalSurface.currentTerminalSize
        }
    }

    func activeTmuxPaneID(in paneIDs: [String: TerminalPaneView]) -> String? {
        guard let active = activePane() ?? firstPane() else { return nil }
        return paneIDs.first(where: { $0.value === active })?.key
    }

    private func installTmuxNode(
        _ node: TmuxLayoutNode,
        panes: [String: TerminalPaneView],
        into container: SplitTerminalView
    ) {
        switch node {
        case let .pane(id, _):
            guard let pane = panes[id] else { return }
            container.configurePane(pane)
            configureTmuxArrangedSubview(pane)
            container.addArrangedSubview(pane)
        case let .split(axis, _, children):
            container.isVertical = axis == .horizontal
            container.autoresizesSubviews = false
            let lengths = children.map { child -> CGFloat in
                switch child {
                case let .pane(_, rect), let .split(_, rect, _):
                    return CGFloat(axis == .horizontal ? rect.width : rect.height)
                }
            }
            let total = lengths.reduce(0, +)
            container.tmuxLayoutProportions = total > 0 ? lengths.map { $0 / total } : nil
            container.needsInitialRebalance = true
            container.needsLayout = true
            for child in children {
                if case .pane = child {
                    installTmuxNode(child, panes: panes, into: container)
                } else {
                    let nested = SplitTerminalView(axis: .vertical, pane: nil, paneDragCoordinator: paneDragCoordinator)
                    configureTmuxArrangedSubview(nested)
                    installTmuxNode(child, panes: panes, into: nested)
                    container.addArrangedSubview(nested)
                }
            }
            container.updateTmuxProportionConstraints()
        }
    }

    private func updateTmuxProportionConstraints() {
        NSLayoutConstraint.deactivate(tmuxProportionConstraints)
        tmuxProportionConstraints.removeAll()
        guard let proportions = tmuxLayoutProportions,
              proportions.count == arrangedSubviews.count,
              let first = arrangedSubviews.first,
              let firstProportion = proportions.first,
              firstProportion > 0
        else { return }
        for index in 1..<arrangedSubviews.count {
            let multiplier = proportions[index] / firstProportion
            let constraint: NSLayoutConstraint
            if isVertical {
                constraint = arrangedSubviews[index].widthAnchor.constraint(
                    equalTo: first.widthAnchor,
                    multiplier: multiplier
                )
            } else {
                constraint = arrangedSubviews[index].heightAnchor.constraint(
                    equalTo: first.heightAnchor,
                    multiplier: multiplier
                )
            }
            constraint.priority = .init(999)
            tmuxProportionConstraints.append(constraint)
        }
        NSLayoutConstraint.activate(tmuxProportionConstraints)
    }

    private func configureTmuxArrangedSubview(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            subview.setContentHuggingPriority(.defaultLow, for: orientation)
            subview.setContentCompressionResistancePriority(.defaultLow, for: orientation)
        }
    }

    @discardableResult
    func applyTmuxLayoutProportions() -> Bool {
        guard !isApplyingTmuxProportions,
              let proportions = tmuxLayoutProportions,
              applyLayoutProportions(proportions)
        else { return false }
        return true
    }

    @discardableResult
    func applyLayoutProportions(_ proportions: [CGFloat]) -> Bool {
        guard !isApplyingTmuxProportions,
              proportions.count == arrangedSubviews.count,
              arrangedSubviews.count > 1
        else { return false }
        let availableLength = max(
            0,
            (isVertical ? bounds.width : bounds.height)
                - dividerThickness * CGFloat(arrangedSubviews.count - 1)
        )
        guard availableLength > 0 else {
            needsInitialRebalance = true
            return false
        }
        isApplyingTmuxProportions = true
        var cursor = isVertical ? bounds.minX : bounds.maxY
        for (index, subview) in arrangedSubviews.enumerated() {
            let length: CGFloat
            if index == arrangedSubviews.count - 1 {
                length = isVertical ? bounds.maxX - cursor : cursor - bounds.minY
            } else {
                length = availableLength * proportions[index]
            }
            if isVertical {
                subview.frame = NSRect(x: cursor, y: bounds.minY, width: length, height: bounds.height)
                cursor += length + dividerThickness
            } else {
                cursor -= length
                subview.frame = NSRect(x: bounds.minX, y: cursor, width: bounds.width, height: length)
                cursor -= dividerThickness
            }
        }
        isApplyingTmuxProportions = false
        return true
    }

    private func applyTmuxLayoutProportionsRecursively() {
        applyTmuxLayoutProportions()
        for case let nested as SplitTerminalView in arrangedSubviews {
            nested.applyTmuxLayoutProportionsRecursively()
        }
    }

    private func replaceArrangedSlot(_ oldView: NSView, with newView: NSView) {
        guard let index = arrangedSubviews.firstIndex(of: oldView) else { return }
        let proportions = layoutProportions()?.map { CGFloat($0) }
        let frame = oldView.frame
        removeArrangedSubview(oldView)
        oldView.removeFromSuperview()
        newView.frame = frame
        insertArrangedSubview(newView, at: index)
        layoutSubtreeIfNeeded()
        if let proportions {
            _ = applyLayoutProportions(proportions)
            pendingSlotReplacementProportions = proportions
        }
    }
}
