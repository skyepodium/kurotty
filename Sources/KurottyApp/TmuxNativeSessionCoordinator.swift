import AppKit

@MainActor
final class TmuxNativeSessionCoordinator {
    private weak var controller: TerminalWindowController?
    private let sessionID = UUID()
    private let gatewaySurface: TerminalSurfaceView
    private let gatewayTab: NSTabViewItem
    private let gatewayPane: TerminalPaneView
    private let gatewayPlaceholder: TmuxGatewayPanePlaceholder?
    private let projectsWholeGatewayTab: Bool
    private let driver: TmuxControlModeDriver
    private var lastKnownGroupStart = 0
    private var items: [String: NSTabViewItem] = [:]
    private var panes: [String: TerminalPaneView] = [:]
    private var sessions: [String: TmuxPaneSession] = [:]
    private var deliveredOutputOffsets: [String: UInt64] = [:]
    private var renderedLayouts: [String: TmuxLayoutNode] = [:]
    private var resizeWorkItems: [String: DispatchWorkItem] = [:]
    private var lastSubmittedWindowSizes: [String: TerminalSize] = [:]
    private var isApplyingSelection = false
    private var didRestoreGateway = false
    private var lastPresentedError: String?
    private var projectionGeneration = 0
    private var renderedSessionID: String?
    private var selectsNativeItemOnNextRender = false

    init?(
        controller: TerminalWindowController,
        gatewaySurface: TerminalSurfaceView,
        gatewayTab: NSTabViewItem,
        gatewayRoot: SplitTerminalView,
        gatewayPane: TerminalPaneView,
        driver: TmuxControlModeDriver
    ) {
        let projectsWholeGatewayTab = gatewayRoot.layoutSlotCount == 1
        let shouldFollowGatewayActivation = controller.tabView.selectedTabViewItem === gatewayTab
            && (projectsWholeGatewayTab || gatewayPane.ownsFirstResponder)
        let gatewayPlaceholder: TmuxGatewayPanePlaceholder?
        if projectsWholeGatewayTab {
            gatewayPlaceholder = nil
        } else {
            guard let placeholder = gatewayRoot.replacePaneWithTmuxPlaceholder(gatewayPane) else {
                return nil
            }
            gatewayPlaceholder = placeholder
        }
        self.controller = controller
        self.gatewaySurface = gatewaySurface
        self.gatewayTab = gatewayTab
        self.gatewayPane = gatewayPane
        self.gatewayPlaceholder = gatewayPlaceholder
        self.projectsWholeGatewayTab = projectsWholeGatewayTab
        self.driver = driver
        lastKnownGroupStart = controller.tabView.indexOfTabViewItem(gatewayTab)
        selectsNativeItemOnNextRender = shouldFollowGatewayActivation
        if projectsWholeGatewayTab {
            controller.tabView.removeTabViewItem(gatewayTab)
        }
        controller.updateTabBar()
    }

    func start() {
        driver.onStateChange = { [weak self] state in self?.apply(state) }
        driver.onPaneOutput = { [weak self] paneID, data in self?.deliver(data, to: paneID) }
        driver.onError = { [weak self] message in self?.presentError(message) }
        driver.onExitWithReason = { [weak self] reason in self?.restoreGateway(exitReason: reason) }
        apply(driver.state)
    }

    var managesSelectedTab: Bool {
        guard let item = controller?.tabView.selectedTabViewItem else { return false }
        return managesTab(item)
    }

    func ownsGateway(_ surface: TerminalSurfaceView) -> Bool { gatewaySurface === surface }

    func hostsGateway(in item: NSTabViewItem) -> Bool { gatewayTab === item }

    var visibleGatewayHost: NSTabViewItem? {
        projectsWholeGatewayTab ? nil : gatewayTab
    }

    var nativeItemCount: Int { items.count }

    func managesTab(_ item: NSTabViewItem) -> Bool {
        items.values.contains { $0 === item }
    }

    func windowID(for item: NSTabViewItem) -> String? {
        items.first { $0.value === item }?.key
    }

    func newWindow() {
        guard managesSelectedTab else { return }
        driver.newWindow()
    }

    func split(_ direction: TerminalPaneSplitDirection) {
        guard managesSelectedTab, let paneID = activePaneID else { return }
        let synchronizedClientSize: (windowID: String, columns: Int, rows: Int)? = {
            guard let item = controller?.tabView.selectedTabViewItem,
                  let windowID = windowID(for: item),
                  let split = item.view as? SplitTerminalView,
                  let layout = driver.state.windows[windowID]?.layout
            else { return nil }
            let sizes = split.tmuxPaneGridSizes(in: panes)
            guard !sizes.isEmpty else { return nil }
            let size = layout.aggregateGridSize(using: sizes)
            lastSubmittedWindowSizes[windowID] = size
            return (windowID, size.columns, size.rows)
        }()
        driver.splitPane(
            paneID,
            direction: direction.axis == .vertical ? .horizontal : .vertical,
            before: !direction.insertsAfterActivePane,
            synchronizedClientSize: synchronizedClientSize
        )
    }

    func closeCurrentPane() {
        guard managesSelectedTab, let paneID = activePaneID else { return }
        driver.killPane(paneID)
    }

    func closeCurrentWindow() {
        guard managesSelectedTab,
              let item = controller?.tabView.selectedTabViewItem,
              let id = windowID(for: item)
        else { return }
        driver.killWindow(id)
    }

    func closeWindow(_ item: NSTabViewItem) {
        guard let id = windowID(for: item) else { return }
        driver.killWindow(id)
    }

    func selectedWindow(_ item: NSTabViewItem) {
        guard !isApplyingSelection, let id = windowID(for: item) else { return }
        if let paneID = driver.state.windows[id]?.activePaneID,
           let pane = panes[paneID] {
            pane.focusTerminal()
        } else if let split = items[id]?.view as? SplitTerminalView {
            split.focusFirstPane()
        }
        driver.selectWindow(id)
    }

    func swapPane(_ direction: TmuxPaneSwapDirection) {
        guard managesSelectedTab, let paneID = activePaneID else { return }
        driver.swapPane(paneID, direction: direction)
    }

    func rotateWindow(_ direction: TmuxRotationDirection) {
        guard managesSelectedTab,
              let item = controller?.tabView.selectedTabViewItem,
              let windowID = windowID(for: item)
        else { return }
        driver.rotateWindow(windowID, direction: direction)
    }

    func toggleZoom() {
        guard managesSelectedTab, let paneID = activePaneID else { return }
        driver.toggleZoom(paneID)
    }

    func selectLayout(_ selection: TmuxLayoutSelection) {
        guard managesSelectedTab, let paneID = activePaneID else { return }
        driver.selectLayout(selection, targetPaneID: paneID)
    }

    func detachClient() {
        guard managesSelectedTab else { return }
        driver.detachClient()
    }

    private var activePaneID: String? {
        guard let split = controller?.currentSplitView() else { return nil }
        return split.activeTmuxPaneID(in: panes) ?? driver.state.focusedPaneID
    }

    private func apply(_ state: TmuxViewerState) {
        guard state.isAttached, let controller else { return }
        let sessionChanged = renderedSessionID != state.sessionID
        if sessionChanged {
            renderedSessionID = state.sessionID
            clearNativeTopology(in: controller)
        }
        guard !state.windowOrder.isEmpty else {
            if !sessionChanged {
                clearNativeTopology(in: controller)
            }
            return
        }
        isApplyingSelection = true
        controller.suppressesTmuxSelectionCallbacks = true
        defer {
            isApplyingSelection = false
            controller.suppressesTmuxSelectionCallbacks = false
        }
        let selectedItemBeforeApply = controller.tabView.selectedTabViewItem
        let shouldFollowTmuxSelection = (selectedItemBeforeApply.map(managesTab) ?? false)
            || selectsNativeItemOnNextRender
        let groupStart = groupStartIndex(in: controller) ?? min(
            lastKnownGroupStart,
            controller.tabView.numberOfTabViewItems
        )

        for paneID in state.panes.keys where panes[paneID] == nil {
            let generation = projectionGeneration
            let session = TmuxPaneSession(
                writeHandler: { [weak self, weak driver] text in
                    guard self?.mayMutate(generation: generation) == true else { return }
                    driver?.sendKeys(to: paneID, text: text)
                },
                resizeHandler: { [weak self] columns, rows in
                    Task { @MainActor in
                        self?.scheduleResize(
                            for: paneID,
                            columns: columns,
                            rows: rows,
                            generation: generation
                        )
                    }
                },
                stopHandler: { [weak self, weak driver] in
                    guard self?.mayMutate(generation: generation) == true else { return }
                    driver?.killPane(paneID)
                }
            )
            let pane = TerminalPaneView(frame: .zero, session: session)
            pane.automaticallyFocusesWhenAttached = false
            pane.closeRequested = { [weak self, weak driver] pane in
                guard self?.panes[paneID] === pane,
                      self?.mayMutate(generation: generation) == true
                else { return }
                driver?.killPane(paneID)
            }
            pane.focusChanged = { [weak self] pane in self?.selectPaneIfNeeded(paneID, pane: pane) }
            sessions[paneID] = session
            panes[paneID] = pane
        }

        let renderedWindowOrder = state.windowOrder.filter { state.windows[$0]?.layout != nil }
        for windowID in renderedWindowOrder {
            guard let window = state.windows[windowID], let layout = window.layout else { continue }
            reconcileSubmittedSizes(windowID: windowID, layout: layout)
            let item: NSTabViewItem
            if let existing = items[windowID] {
                item = existing
            } else {
                item = NSTabViewItem(identifier: scopedIdentifier(for: windowID))
                item.view = SplitTerminalView(axis: .vertical, pane: nil, paneDragCoordinator: controller.paneDragCoordinator)
                items[windowID] = item
            }
            item.label = window.name.isEmpty ? windowID : window.name
            if item === controller.tabView.selectedTabViewItem {
                controller.window?.title = item.label
            }
            if renderedLayouts[windowID] != layout,
               let split = item.view as? SplitTerminalView {
                split.installTmuxLayout(layout, panes: panes)
                split.applyChromeTheme(controller.chromeTheme)
                renderedLayouts[windowID] = layout
            }
            for paneID in layout.paneIDs {
                let generation = projectionGeneration
                panes[paneID]?.closeRequested = { [weak self, weak driver] pane in
                    guard self?.panes[paneID] === pane,
                          self?.mayMutate(generation: generation) == true
                    else { return }
                    driver?.killPane(paneID)
                }
                panes[paneID]?.focusChanged = { [weak self] pane in self?.selectPaneIfNeeded(paneID, pane: pane) }
                panes[paneID]?.detachDragRequested = nil
            }
        }

        for id in Array(items.keys) where !renderedWindowOrder.contains(id) {
            renderedLayouts[id] = nil
            lastSubmittedWindowSizes[id] = nil
            resizeWorkItems.removeValue(forKey: id)?.cancel()
            if let item = items.removeValue(forKey: id) { controller.tabView.removeTabViewItem(item) }
        }
        for paneID in Array(panes.keys) where state.panes[paneID] == nil {
            sessions.removeValue(forKey: paneID)?.finish()
            panes.removeValue(forKey: paneID)?.removeFromSuperview()
            deliveredOutputOffsets[paneID] = nil
        }
        for (offset, windowID) in renderedWindowOrder.enumerated() {
            guard let item = items[windowID] else { continue }
            let currentIndex = controller.tabView.indexOfTabViewItem(item)
            let desiredIndex = min(groupStart + offset, controller.tabView.numberOfTabViewItems)
            guard currentIndex != desiredIndex else { continue }
            if currentIndex != NSNotFound {
                controller.tabView.removeTabViewItem(item)
            }
            controller.tabView.insertTabViewItem(
                item,
                at: min(desiredIndex, controller.tabView.numberOfTabViewItems)
            )
        }
        lastKnownGroupStart = groupStartIndex(in: controller) ?? groupStart
        if shouldFollowTmuxSelection,
           let activeID = state.activeWindowID,
           let item = items[activeID] {
            controller.tabView.selectTabViewItem(item)
            selectsNativeItemOnNextRender = false
        }
        for (paneID, paneState) in state.panes {
            panes[paneID]?.setTmuxDisplayTitle(paneState.title.isEmpty ? paneID : paneState.title)
            let replay = paneState.replayOutput(after: deliveredOutputOffsets[paneID])
            if replay.requiresFullReplay {
                sessions[paneID]?.receive(Data([0x1b, 0x63]))
            }
            sessions[paneID]?.receive(replay.data)
            deliveredOutputOffsets[paneID] = replay.nextOffset
        }
        controller.updateTabBar()
        let focusedPaneID = state.activeWindowID.flatMap { state.windows[$0]?.activePaneID }
            ?? state.focusedPaneID
        if shouldFollowTmuxSelection,
           let focusedPaneID,
           panes[focusedPaneID]?.window === controller.window {
            panes[focusedPaneID]?.focusTerminal()
        }
    }

    private func scopedIdentifier(for windowID: String) -> String {
        "tmux-native:\(sessionID.uuidString):\(windowID)"
    }

    private func groupStartIndex(in controller: TerminalWindowController) -> Int? {
        if let hostGroupStart = controller.nativeGroupStartIndex(for: self) {
            return hostGroupStart
        }
        let itemIndices = items.values.compactMap { item -> Int? in
            let index = controller.tabView.indexOfTabViewItem(item)
            return index == NSNotFound ? nil : index
        }
        if let first = itemIndices.min() { return first }
        return nil
    }

    private func clearNativeTopology(in controller: TerminalWindowController) {
        let selectedItem = controller.tabView.selectedTabViewItem
        let selectedWasManaged = selectedItem.map(managesTab) ?? false
        selectsNativeItemOnNextRender = selectsNativeItemOnNextRender
            || selectedWasManaged
        isApplyingSelection = true
        controller.suppressesTmuxSelectionCallbacks = true
        defer {
            isApplyingSelection = false
            controller.suppressesTmuxSelectionCallbacks = false
        }

        projectionGeneration &+= 1
        for item in items.values {
            controller.tabView.removeTabViewItem(item)
        }
        items.removeAll()
        renderedLayouts.removeAll()
        for pane in panes.values {
            pane.closeRequested = nil
            pane.focusChanged = nil
            pane.detachDragRequested = nil
            pane.removeFromSuperview()
        }
        sessions.values.forEach { $0.finish() }
        sessions.removeAll()
        panes.removeAll()
        deliveredOutputOffsets.removeAll()
        resizeWorkItems.values.forEach { $0.cancel() }
        resizeWorkItems.removeAll()
        lastSubmittedWindowSizes.removeAll()

        if selectedWasManaged,
           let visibleGatewayHost,
           controller.tabView.indexOfTabViewItem(visibleGatewayHost) != NSNotFound {
            controller.tabView.selectTabViewItem(visibleGatewayHost)
        }
        controller.updateTabBar()
    }

    private func mayMutate(generation: Int) -> Bool {
        !didRestoreGateway && generation == projectionGeneration
    }

    private func deliver(_ data: Data, to paneID: String) {
        guard let session = sessions[paneID] else { return }
        session.receive(data)
        deliveredOutputOffsets[paneID] = driver.state.panes[paneID]?.outputHistoryEndOffset
    }

    private func selectPaneIfNeeded(_ paneID: String, pane: TerminalPaneView) {
        guard !isApplyingSelection, pane.ownsFirstResponder else { return }
        let activePaneID = driver.state.windows.values.first {
            $0.canonicalLayout?.paneIDs.contains(paneID) == true
        }?.activePaneID
        guard activePaneID != paneID else { return }
        driver.selectPane(paneID)
    }

    private func scheduleResize(
        for paneID: String,
        columns: Int,
        rows: Int,
        generation: Int
    ) {
        guard mayMutate(generation: generation),
              columns > 1, rows > 1,
              let windowID = driver.state.windows.first(where: { $0.value.layout?.paneIDs.contains(paneID) == true })?.key
        else { return }
        resizeWorkItems[windowID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.synchronizeTmuxSizes(windowID: windowID, generation: generation)
            }
        }
        resizeWorkItems[windowID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func synchronizeTmuxSizes(windowID: String, generation: Int) {
        resizeWorkItems[windowID] = nil
        guard mayMutate(generation: generation),
              let item = items[windowID],
              let split = item.view as? SplitTerminalView,
              let layout = driver.state.windows[windowID]?.layout
        else { return }
        let sizes = split.tmuxPaneGridSizes(in: panes)
        guard !sizes.isEmpty else { return }
        let windowSize = layout.aggregateGridSize(using: sizes)
        if lastSubmittedWindowSizes[windowID] != windowSize,
           layout.rect.width != windowSize.columns || layout.rect.height != windowSize.rows {
            lastSubmittedWindowSizes[windowID] = windowSize
            driver.resizeClient(windowID: windowID, columns: windowSize.columns, rows: windowSize.rows)
        }
    }

    private func reconcileSubmittedSizes(windowID: String, layout: TmuxLayoutNode) {
        if let submitted = lastSubmittedWindowSizes[windowID],
           submitted.columns != layout.rect.width || submitted.rows != layout.rect.height {
            lastSubmittedWindowSizes[windowID] = nil
        }
    }

    private func restoreGateway(exitReason: String? = nil) {
        guard !didRestoreGateway, let controller else { return }
        didRestoreGateway = true
        let selectedItemBeforeRestore = controller.tabView.selectedTabViewItem
        let shouldSelectGateway = selectedItemBeforeRestore.map(managesTab) ?? false
        let groupStart = groupStartIndex(in: controller) ?? min(
            lastKnownGroupStart,
            controller.tabView.numberOfTabViewItems
        )
        clearNativeTopology(in: controller)
        renderedSessionID = nil

        isApplyingSelection = true
        controller.suppressesTmuxSelectionCallbacks = true
        defer {
            isApplyingSelection = false
            controller.suppressesTmuxSelectionCallbacks = false
        }
        if projectsWholeGatewayTab,
           controller.tabView.indexOfTabViewItem(gatewayTab) == NSNotFound {
            controller.tabView.insertTabViewItem(
                gatewayTab,
                at: min(groupStart, controller.tabView.numberOfTabViewItems)
            )
        } else if let gatewayPlaceholder,
                  let gatewayRoot = gatewayTab.view as? SplitTerminalView,
                  !gatewayRoot.restorePane(gatewayPane, replacing: gatewayPlaceholder) {
            gatewayRoot.appendDetachedPaneAsTabRoot(gatewayPane)
        }
        if shouldSelectGateway || controller.tabView.selectedTabViewItem == nil {
            if controller.tabView.indexOfTabViewItem(gatewayTab) != NSNotFound {
                controller.tabView.selectTabViewItem(gatewayTab)
            }
        }
        driver.onStateChange = nil
        driver.onPaneOutput = nil
        driver.onError = nil
        driver.onExit = nil
        driver.onExitWithReason = nil
        controller.tmuxCoordinatorDidExit(self)
        controller.updateTabBar()
        if let exitReason,
           !exitReason.localizedCaseInsensitiveContains("detach") {
            presentError(exitReason)
        }
    }

    private func presentError(_ message: String) {
        let normalized = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !normalized.isEmpty, normalized != lastPresentedError else { return }
        lastPresentedError = normalized
        guard let window = controller?.window, window.isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Tmux session error"
        alert.informativeText = normalized
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

private extension TmuxLayoutNode {
    var rect: TmuxLayoutRect {
        switch self {
        case let .pane(_, rect), let .split(_, rect, _): rect
        }
    }

    var paneRects: [String: TmuxLayoutRect] {
        switch self {
        case let .pane(id, rect): [id: rect]
        case let .split(_, _, children):
            children.reduce(into: [:]) { result, child in
                result.merge(child.paneRects, uniquingKeysWith: { _, latest in latest })
            }
        }
    }

    func aggregateGridSize(using paneSizes: [String: TerminalSize]) -> TerminalSize {
        switch self {
        case let .pane(id, rect):
            return paneSizes[id] ?? TerminalSize(columns: rect.width, rows: rect.height)
        case let .split(axis, _, children):
            let childSizes = children.map { $0.aggregateGridSize(using: paneSizes) }
            guard !childSizes.isEmpty else { return TerminalSize(columns: 1, rows: 1) }
            switch axis {
            case .horizontal:
                return TerminalSize(
                    columns: childSizes.reduce(0) { $0 + $1.columns } + childSizes.count - 1,
                    rows: childSizes.map(\.rows).max() ?? 1
                )
            case .vertical:
                return TerminalSize(
                    columns: childSizes.map(\.columns).max() ?? 1,
                    rows: childSizes.reduce(0) { $0 + $1.rows } + childSizes.count - 1
                )
            }
        }
    }
}
