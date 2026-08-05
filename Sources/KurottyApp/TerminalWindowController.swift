import AppKit

@MainActor
final class TerminalWindowController: NSWindowController, NSTabViewDelegate, NSWindowDelegate {
    private let dropTargetView = TerminalPaneDropTargetView()
    let paneDragCoordinator: TerminalPaneDragCoordinator
    private var rootView: NSView {
        dropTargetView
    }
    private let tabBarView = NSView()
    private let topBarSeparatorView = NSView()
    private let historyToggleButton = ChromeIconButton(
        symbolName: IconSymbol.sidebarLeading,
        accessibilityLabel: AppLocalization.string(.commandHistory),
        target: nil,
        action: nil
    )
    private let explorerToggleButton = ChromeIconButton(
        symbolName: IconSymbol.sidebarTrailing,
        accessibilityLabel: AppLocalization.string(.fileExplorer),
        target: nil,
        action: nil
    )
    private let tabStackView = NSStackView()
    let tabView = NSTabView()
    // Left sidebar split chrome; layout and handlers live in
    // TerminalWindowCommandHistory.swift to keep this controller thin. The
    // pane hosts one container that switches between the command-history and
    // agent-session sections.
    let commandHistorySplitView = NSSplitView()
    let leftSidebarPanel = TerminalLeftSidebarPanelView()
    var commandHistoryPanel: TerminalCommandHistoryPanelView {
        leftSidebarPanel.historyPanel
    }
    var agentSessionPanel: TerminalAgentSessionPanelView {
        leftSidebarPanel.agentSessionPanel
    }
    let terminalContentHostView = NSView()
    // Right file-explorer pane; layout, cwd tracking, and editor-tab handlers
    // live in TerminalWindowFileExplorer.swift / TerminalWindowEditorTabs.swift.
    let fileExplorerPanel = TerminalFileExplorerPanelView()
    /// Bottom status bar. It owns the bottom strip exactly as the chrome bar
    /// owns the top one: the split view is pinned to its `topAnchor`, so a
    /// collapsed bar gives every point back to the terminal content.
    let statusBarView = TerminalStatusBarView(frame: .zero)
    private var tabBarHeightConstraint: NSLayoutConstraint?
    /// Sidebar width constraints stay active only while the panel is shown: a
    /// hidden view still participates in Auto Layout, so leaving them on keeps
    /// the split view reserving a sliver of width plus its divider.
    /// Per-pane scrollback persistence for this window. `nil` when Application
    /// Support is unavailable; every call site treats that as "no snapshots".
    /// Settable so tests can point it at a temporary root instead of the user's
    /// real Application Support directory.
    var scrollbackSnapshotCoordinator: TerminalScrollbackSnapshotCoordinator?
    var chromeTheme: DesignTokens.ChromeTheme
    private var lastAppliedWindowSettings: WindowSettings
    private var tmuxCoordinators: [TmuxNativeSessionCoordinator] = []
    var suppressesTmuxSelectionCallbacks = false
    var openCommandPaletteRequested: (() -> Void)?

    convenience init(paneDragCoordinator: TerminalPaneDragCoordinator) {
        self.init(initialPane: nil, paneDragCoordinator: paneDragCoordinator)
    }

    convenience init(detachedPane pane: TerminalPaneView, paneDragCoordinator: TerminalPaneDragCoordinator) {
        self.init(initialPane: pane, paneDragCoordinator: paneDragCoordinator)
    }

    private init(initialPane: TerminalPaneView?, paneDragCoordinator: TerminalPaneDragCoordinator) {
        self.paneDragCoordinator = paneDragCoordinator
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        chromeTheme = DesignTokens.ChromeTheme.theme(for: settings)
        lastAppliedWindowSettings = settings.window
        // Launch-only: the flag is read once here and gates both capture and
        // restore for this window's lifetime.
        scrollbackSnapshotCoordinator = TerminalScrollbackSnapshotCoordinator.makeDefault(
            isEnabled: settings.terminal.restoreScrollbackOnLaunch
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: settings.window.width, height: settings.window.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.Bundle.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self
        configureTabs(initialPane: initialPane)
        statusBarView.setEnabled(settings.terminal.statusBarEnabled)
        applyChromeTheme(chromeTheme)
        observeSettings()
        observeTerminalTitles()
        observeTmuxControlMode()
        observePaneFocus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func newTab() {
        if let coordinator = selectedTmuxCoordinator { coordinator.newWindow(); return }
        addTab(with: nil)
    }

    func attachDraggedPaneAsTab(_ pane: TerminalPaneView) {
        addTab(with: pane)
    }

    func detachPaneForDrag(_ pane: TerminalPaneView) -> TerminalPaneView? {
        guard let splitView = splitView(containing: pane) else {
            return nil
        }
        return splitView.detachPaneForDrag(pane)
    }

    private func addTab(with pane: TerminalPaneView?) {
        let identifier = UUID().uuidString
        let splitView = SplitTerminalView(axis: .vertical, pane: nil, paneDragCoordinator: paneDragCoordinator)
        if let pane {
            splitView.appendDetachedPaneAsTabRoot(pane)
        } else {
            splitView.appendDetachedPaneAsTabRoot(TerminalPaneView())
        }
        splitView.applyChromeTheme(chromeTheme)
        let item = NSTabViewItem(identifier: identifier)
        item.label = pane?.displayTitle ?? defaultTabLabel()
        item.view = splitView
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        updateTabBar()
        currentSplitView()?.focusFirstPane()
        refreshStatusBarPanes()
    }

    func splitVertically() {
        split(direction: .right)
    }

    func splitHorizontally() {
        split(direction: .down)
    }

    func split(direction: TerminalPaneSplitDirection) {
        if let coordinator = selectedTmuxCoordinator { coordinator.split(direction); return }
        currentSplitView()?.split(direction: direction)
        refreshStatusBarPanes()
    }

    func focusPane(_ direction: TerminalPaneFocusDirection) {
        currentSplitView()?.focusPane(direction)
    }

    func sendTextToActivePane(_ text: String) {
        currentSplitView()?.sendTextToActivePane(text)
    }

    func commandSpanPaletteCommands() -> [TerminalCommandSpanCommand] {
        currentSplitView()?.commandSpanPaletteCommands() ?? []
    }

    func executeCommandSpanPaletteCommand(_ command: TerminalCommandSpanCommand) -> Bool {
        currentSplitView()?.executeCommandSpanPaletteCommand(command) ?? false
    }

    /// The palette registry for the selected tab, carrying the quick commands
    /// visible in the active pane's working directory. Directory-scoped
    /// commands outside that directory are never registered, so they cannot
    /// appear in the palette at all.
    func commandPaletteRegistry() -> TerminalCommandRegistry {
        let registry = selectedTmuxCoordinator == nil ? TerminalCommandRegistry.localized : .localizedTmuxControl
        let workingDirectory = quickCommandWorkingDirectory
        return registry.registering(
            quickCommands: QuickCommandStore.shared.commands(forWorkingDirectory: workingDirectory),
            workingDirectory: workingDirectory,
            language: AppLocalization.language
        )
    }

    func swapTmuxPane(_ direction: TmuxPaneSwapDirection) {
        selectedTmuxCoordinator?.swapPane(direction)
    }

    func rotateTmuxWindow(_ direction: TmuxRotationDirection) {
        selectedTmuxCoordinator?.rotateWindow(direction)
    }

    func toggleTmuxZoom() {
        selectedTmuxCoordinator?.toggleZoom()
    }

    func selectTmuxLayout(_ selection: TmuxLayoutSelection) {
        selectedTmuxCoordinator?.selectLayout(selection)
    }

    func detachTmuxClient() {
        selectedTmuxCoordinator?.detachClient()
    }

    func enterCopyMode() {
        currentSplitView()?.focusFirstPane()
    }

    func openQuickTerminal() {
        newTab()
    }

    func findTerminalOutput() {
        currentSplitView()?.showSearchInActivePane()
    }

    func layoutOnlyWorkspaceDescriptor() -> WorkspaceSnapshotCoordinator.WorkspaceDescriptor {
        workspaceDescriptor(capturingScrollback: false)
    }

    /// Layout descriptor for this window. With `capturingScrollback` on, every
    /// live pane's trailing rows are serialized and enqueued for writing, and
    /// the resulting reference is recorded on that pane's descriptor.
    func workspaceDescriptor(
        capturingScrollback: Bool
    ) -> WorkspaceSnapshotCoordinator.WorkspaceDescriptor {
        let windowID = window?.identifier?.rawValue ?? AppConstants.Workspace.defaultWindowIdentifier
        return WorkspaceSnapshotCoordinator.WorkspaceDescriptor(
            windows: [
                WorkspaceSnapshotCoordinator.WindowDescriptor(
                    id: windowID,
                    title: nil,
                    frame: windowFrameSnapshot,
                    tabs: layoutOnlyTabDescriptors(capturingScrollback: capturingScrollback),
                    activeTabID: selectedTabID
                ),
            ],
            activeWindowID: windowID
        )
    }

    func closeCurrentTab() {
        if let coordinator = selectedTmuxCoordinator { coordinator.closeCurrentWindow(); return }
        guard let item = tabView.selectedTabViewItem else {
            return
        }
        guard !hasActiveTmuxProjection(hosting: item) else { return }
        guard confirmEditorTabCloseIfNeeded(item) else { return }
        if tabView.numberOfTabViewItems <= 1 {
            // `performClose` runs `windowShouldClose`, which confirms running
            // processes for the whole window; a second tab-level prompt here
            // would ask twice for the same close.
            window?.performClose(nil)
            return
        }
        guard confirmCloseIfRunningProcess(shellProcessIdentifiers: shellProcessIdentifiers(in: item)) else {
            return
        }
        closeTab(item)
        currentSplitView()?.focusFirstPane()
    }

    func closeCurrentPane() {
        if let coordinator = selectedTmuxCoordinator { coordinator.closeCurrentPane(); return }
        guard currentSplitView()?.closeActivePane() == true else {
            closeCurrentTab()
            return
        }
        currentSplitView()?.focusFirstPane()
        refreshStatusBarPanes()
    }

    func selectNextTab() {
        guard tabView.numberOfTabViewItems > 1 else {
            return
        }
        tabView.selectNextTabViewItem(nil)
        updateTabBar()
        if selectedTmuxCoordinator == nil { currentSplitView()?.focusFirstPane() }
    }

    func selectPreviousTab() {
        guard tabView.numberOfTabViewItems > 1 else {
            return
        }
        tabView.selectPreviousTabViewItem(nil)
        updateTabBar()
        if selectedTmuxCoordinator == nil { currentSplitView()?.focusFirstPane() }
    }

    private func configureTabs(initialPane: TerminalPaneView?) {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        rootView.layer?.backgroundColor = chromeTheme.windowBackground.cgColor
        window?.contentView = rootView
        dropTargetView.onPaneDrop = { [weak self] in
            guard let self else {
                return false
            }
            return self.paneDragCoordinator.moveDraggedPaneToTab(in: self)
        }
        dropTargetView.onPaneCanDrop = { [weak self] in
            guard let self else {
                return false
            }
            return self.paneDragCoordinator.canMoveDraggedPane(to: self)
        }

        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        tabBarView.wantsLayer = true
        tabBarView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        tabBarView.layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor
        tabBarView.layer?.borderWidth = 0
        tabBarView.layer?.cornerRadius = DesignTokens.Component.terminalTopBarCornerRadiusPX
        tabBarView.layer?.masksToBounds = true

        topBarSeparatorView.wantsLayer = true
        topBarSeparatorView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        topBarSeparatorView.layer?.backgroundColor = chromeTheme.borderHairline.cgColor
        topBarSeparatorView.translatesAutoresizingMaskIntoConstraints = false

        tabStackView.orientation = .horizontal
        tabStackView.alignment = .centerY
        tabStackView.spacing = DesignTokens.Component.terminalTabStackGapPX
        tabStackView.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Component.terminalTabStackInsetTopPX,
            left: DesignTokens.Component.terminalTabStackInsetLeftPX,
            bottom: DesignTokens.Component.terminalTabStackInsetBottomPX,
            right: DesignTokens.Component.terminalTabStackInsetRightPX
        )
        tabStackView.translatesAutoresizingMaskIntoConstraints = false

        tabView.tabViewType = .noTabsNoBorder
        tabView.delegate = self
        tabView.drawsBackground = false
        tabView.translatesAutoresizingMaskIntoConstraints = false
        // The chrome bar spans the whole window (above the split view) so the
        // sidebar toggles sit in the window corners and panel content starts
        // below the title bar instead of colliding with the traffic lights.
        rootView.addSubview(tabBarView)
        terminalContentHostView.addSubview(tabView)
        tabBarView.addSubview(historyToggleButton)
        tabBarView.addSubview(explorerToggleButton)
        tabBarView.addSubview(tabStackView)
        tabBarView.addSubview(topBarSeparatorView)
        configureSidebarToggleButtons()

        let tabBarHeightConstraint = tabBarView.heightAnchor.constraint(equalToConstant: 0)
        self.tabBarHeightConstraint = tabBarHeightConstraint
        NSLayoutConstraint.activate([
            tabBarView.leadingAnchor.constraint(
                equalTo: rootView.leadingAnchor,
                constant: DesignTokens.Component.terminalTabBarHorizontalInsetPX
            ),
            tabBarView.trailingAnchor.constraint(
                equalTo: rootView.trailingAnchor,
                constant: -DesignTokens.Component.terminalTabBarHorizontalInsetPX
            ),
            tabBarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            tabBarHeightConstraint,

            historyToggleButton.leadingAnchor.constraint(
                equalTo: tabBarView.leadingAnchor,
                constant: DesignTokens.Component.terminalTrafficLightClearancePX
            ),
            historyToggleButton.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),
            explorerToggleButton.trailingAnchor.constraint(
                equalTo: tabBarView.trailingAnchor,
                constant: -DesignTokens.Component.terminalTabBarHorizontalInsetPX
            ),
            explorerToggleButton.centerYAnchor.constraint(equalTo: tabBarView.centerYAnchor),

            tabStackView.leadingAnchor.constraint(
                equalTo: historyToggleButton.trailingAnchor,
                constant: DesignTokens.Component.terminalTabBarSideButtonInsetPX
            ),
            tabStackView.trailingAnchor.constraint(
                lessThanOrEqualTo: explorerToggleButton.leadingAnchor,
                constant: -DesignTokens.Component.terminalTabBarSideButtonInsetPX
            ),
            tabStackView.topAnchor.constraint(equalTo: tabBarView.topAnchor),
            tabStackView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),

            topBarSeparatorView.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
            topBarSeparatorView.trailingAnchor.constraint(equalTo: tabBarView.trailingAnchor),
            topBarSeparatorView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            topBarSeparatorView.heightAnchor.constraint(equalToConstant: DesignTokens.Component.hairlinePX),

            tabView.leadingAnchor.constraint(equalTo: terminalContentHostView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: terminalContentHostView.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: terminalContentHostView.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: terminalContentHostView.bottomAnchor),
        ])
        // Mounted before the split configuration because the split's bottom
        // constraint is pinned to `statusBarView.topAnchor`: Auto Layout
        // requires both views to already share `rootView` as an ancestor when
        // that constraint is activated.
        statusBarView.dataSource = self
        statusBarView.attach(to: rootView)
        statusBarView.applyChromeTheme(chromeTheme)

        configureCommandHistorySplit(in: rootView)
        configureFileExplorerPane()
        addTab(with: initialPane)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        window?.title = tabViewItem?.label ?? AppConstants.Bundle.displayName
        updateTabBar()
        refreshFileExplorerRootDirectory()
        refreshStatusBarPanes()
        if suppressesTmuxSelectionCallbacks {
            return
        }
        if let tabViewItem,
           let coordinator = tmuxCoordinator(managing: tabViewItem) {
            coordinator.selectedWindow(tabViewItem)
        } else {
            currentSplitView()?.focusFirstPane()
        }
    }

    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        guard let selectedItem = tabView.selectedTabViewItem,
              selectedItem !== tabViewItem,
              let splitView = selectedItem.view as? SplitTerminalView
        else {
            return
        }
        splitView.closeSearchInAllPanes()
    }

    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared,
        )
    }

    private func observeTerminalTitles() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(terminalTitleDidChange(_:)),
            name: TerminalSurfaceView.titleDidChangeNotification,
            object: nil
        )
    }

    private func observeTmuxControlMode() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tmuxControlModeDidActivate(_:)),
            name: TerminalSurfaceView.tmuxControlModeDidActivateNotification,
            object: nil
        )
    }

    @objc private func tmuxControlModeDidActivate(_ notification: Notification) {
        guard let surface = notification.object as? TerminalSurfaceView,
              let gatewayTab = tabItem(containing: surface),
              let gatewayRoot = gatewayTab.view as? SplitTerminalView,
              let gatewayPane = gatewayRoot.pane(containing: surface),
              !tmuxCoordinators.contains(where: { $0.ownsGateway(surface) }),
              let driver = notification.userInfo?[TerminalSurfaceView.tmuxControlModeDriverNotificationKey] as? TmuxControlModeDriver
        else { return }
        guard let coordinator = TmuxNativeSessionCoordinator(
            controller: self,
            gatewaySurface: surface,
            gatewayTab: gatewayTab,
            gatewayRoot: gatewayRoot,
            gatewayPane: gatewayPane,
            driver: driver
        ) else { return }
        tmuxCoordinators.append(coordinator)
        coordinator.start()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        chromeTheme = DesignTokens.ChromeTheme.theme(for: settings)
        applyChromeTheme(chromeTheme)
        // Live-applied: the bar collapses or expands in place, and a collapsed
        // bar tears its sampling timer down instead of idling.
        statusBarView.setEnabled(settings.terminal.statusBarEnabled)
        applyWindowSettingsIfChanged(settings)
    }

    private func applyWindowSettingsIfChanged(_ settings: AppSettings) {
        // Every settings edit (colors, theme, font, shell) posts the same
        // notification. Only an actual window-size settings change may resize
        // and re-center the window; unrelated edits must not move it.
        // Font-size changes do not resize the window here: window size is tied
        // exclusively to settings.window, and the terminal surfaces reflow
        // their grids for font changes on their own.
        guard settings.window != lastAppliedWindowSettings else { return }
        lastAppliedWindowSettings = settings.window
        window?.setContentSize(NSSize(width: settings.window.width, height: settings.window.height))
        window?.center()
    }

    private func applyChromeTheme(_ theme: DesignTokens.ChromeTheme) {
        chromeTheme = theme
        window?.appearance = chromeTheme.windowAppearance
        window?.backgroundColor = chromeTheme.windowBackground
        dropTargetView.chromeTheme = chromeTheme
        rootView.layer?.backgroundColor = chromeTheme.windowBackground.cgColor
        tabBarView.layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor
        topBarSeparatorView.layer?.backgroundColor = chromeTheme.borderHairline.cgColor
        leftSidebarPanel.applyChromeTheme(chromeTheme)
        fileExplorerPanel.applyChromeTheme(chromeTheme)
        statusBarView.applyChromeTheme(chromeTheme)
        applyChromeThemeToTabSplits(chromeTheme)
        // Both toggles take their full ramp from the theme, so a light theme
        // has to reach them here too — not only their on/off tint.
        updateSidebarToggleButtonStates()
        updateTabBar()
    }

    private func applyChromeThemeToTabSplits(_ theme: DesignTokens.ChromeTheme) {
        for index in 0..<tabView.numberOfTabViewItems {
            let item = tabView.tabViewItem(at: index)
            if let splitView = item.view as? SplitTerminalView {
                splitView.applyChromeTheme(theme)
            } else if let editor = editorView(in: item) {
                editor.applyChromeTheme(theme)
            } else if let transcript = transcriptView(in: item) {
                transcript.applyChromeTheme(theme)
            }
        }
    }

    @objc private func terminalTitleDidChange(_ notification: Notification) {
        // OSC 7 working-directory changes publish through the same title
        // notification, so the explorer root follows the active pane's cwd
        // here. The refresh recomputes from the active pane and is idempotent.
        refreshFileExplorerRootDirectory()
        workingDirectoryDidChange()
        guard let surface = notification.object as? TerminalSurfaceView,
              let title = notification.userInfo?[TerminalSurfaceView.titleNotificationKey] as? String,
              let item = tabItem(containing: surface)
        else {
            return
        }
        guard tmuxCoordinator(managing: item) == nil else { return }
        item.label = title
        if item === tabView.selectedTabViewItem {
            window?.title = title
        }
        updateTabBar()
    }

    func currentSplitView() -> SplitTerminalView? {
        tabView.selectedTabViewItem?.view as? SplitTerminalView
    }

    var nativeTmuxTabIDs: [String] {
        (0..<tabView.numberOfTabViewItems).compactMap { index in
            let item = tabView.tabViewItem(at: index)
            return tmuxCoordinator(managing: item)?.windowID(for: item)
        }
    }

    var nativeTmuxTabLabels: [String: String] {
        (0..<tabView.numberOfTabViewItems).reduce(into: [:]) { labels, index in
            let item = tabView.tabViewItem(at: index)
            guard let id = tmuxCoordinator(managing: item)?.windowID(for: item) else { return }
            labels[id] = item.label
        }
    }

    var nativeTmuxScopedTabIDs: [String] {
        (0..<tabView.numberOfTabViewItems).compactMap { index in
            let item = tabView.tabViewItem(at: index)
            guard tmuxCoordinator(managing: item) != nil else { return nil }
            return item.identifier as? String
        }
    }

    var tabIdentifiersInOrder: [String] {
        (0..<tabView.numberOfTabViewItems).compactMap {
            tabView.tabViewItem(at: $0).identifier as? String
        }
    }

    var activeTmuxControlSessionCount: Int { tmuxCoordinators.count }
    var hasActiveTmuxControlSession: Bool { !tmuxCoordinators.isEmpty }
    var selectedLayoutSlotCount: Int { currentSplitView()?.layoutSlotCount ?? 0 }
    var selectedProjectionPlaceholderCount: Int { currentSplitView()?.projectionPlaceholderCount ?? 0 }
    var selectedTerminalPanesInLayoutOrder: [TerminalPaneView] {
        currentSplitView()?.terminalPanesInLayoutOrder ?? []
    }
    var selectedLayoutSlotProportions: [Double]? { currentSplitView()?.layoutSlotProportions }
    var selectedSplitViewForTesting: SplitTerminalView? { currentSplitView() }

    private var windowFrameSnapshot: WorkspaceWindowFrameSnapshot? {
        guard let frame = window?.frame else {
            return nil
        }
        return WorkspaceWindowFrameSnapshot(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    private var selectedTabID: String? {
        guard let selectedItem = tabView.selectedTabViewItem else {
            return nil
        }
        return tabID(for: selectedItem, index: tabView.indexOfTabViewItem(selectedItem))
    }

    private func layoutOnlyTabDescriptors(
        capturingScrollback: Bool
    ) -> [WorkspaceSnapshotCoordinator.TabDescriptor] {
        (0..<tabView.numberOfTabViewItems).compactMap { index in
            let item = tabView.tabViewItem(at: index)
            guard let splitView = item.view as? SplitTerminalView else {
                return nil
            }
            let idPrefix = layoutIDPrefix(forTabIndex: index)
            return WorkspaceSnapshotCoordinator.TabDescriptor(
                id: tabID(for: item, index: index),
                title: nil,
                root: splitView.layoutOnlyDescriptor(idPrefix: idPrefix) { pane, paneID in
                    guard capturingScrollback else {
                        return nil
                    }
                    return captureScrollbackSnapshot(of: pane, tabID: idPrefix, paneID: paneID)
                }
            )
        }
    }

    /// Positional tab identity used for pane identifiers and snapshot
    /// references. Deliberately not the tab's `NSTabViewItem` identifier: that
    /// is a fresh UUID per launch, while a restored layout has to line up with
    /// the slot the pane occupied last time.
    func layoutIDPrefix(forTabIndex index: Int) -> String {
        "\(AppConstants.Workspace.tabIdentifierPrefix)\(index)"
    }

    private func tabID(for item: NSTabViewItem, index: Int) -> String {
        if let id = item.identifier as? String, !id.isEmpty {
            return id
        }
        return layoutIDPrefix(forTabIndex: index)
    }

    private func defaultTabLabel() -> String {
        "~ (-zsh)"
    }

    func updateTabBar() {
        // The chrome bar also hosts the sidebar toggles, so it stays visible even
        // with a single tab; only the tab items themselves collapse.
        tabBarHeightConstraint?.constant = DesignTokens.Component.terminalTabBarHeightPX
        tabBarView.isHidden = false
        updateSidebarToggleButtonStates()

        tabStackView.arrangedSubviews.forEach { view in
            tabStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for index in 0..<tabView.numberOfTabViewItems {
            let item = tabView.tabViewItem(at: index)
            let tabItemView = makeTabItemView(title: item.label, index: index, isSelected: item === tabView.selectedTabViewItem)
            tabStackView.addArrangedSubview(tabItemView)
        }

        let addButton = ChromeIconButton(
            symbolName: IconSymbol.add,
            accessibilityLabel: AppLocalization.string(.newTab),
            size: .small,
            target: self,
            action: #selector(newTabButtonPressed(_:))
        )
        addButton.applyChromeTheme(chromeTheme)
        // Deliberate deviation from the theme's achromatic hover: the tab bar
        // tints its own hover with the accent so add/close read as tab actions.
        addButton.normalTintColor = chromeTheme.textSecondary
        addButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(
            DesignTokens.Component.terminalTabButtonHoverAlphaRATIO
        )
        addButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabPlusWidthPX).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabHeightPX).isActive = true
        tabStackView.addArrangedSubview(addButton)
    }

    /// Bottom of the window-wide chrome bar; the split view hangs off this so
    /// sidebars start below the title bar rather than under the traffic lights.
    var chromeBarBottomAnchor: NSLayoutYAxisAnchor {
        tabBarView.bottomAnchor
    }

    private func configureSidebarToggleButtons() {
        historyToggleButton.toolTip = AppLocalization.string(.commandHistory)
        historyToggleButton.target = self
        historyToggleButton.action = #selector(historyToggleButtonPressed(_:))

        explorerToggleButton.toolTip = AppLocalization.string(.fileExplorer)
        explorerToggleButton.target = self
        explorerToggleButton.action = #selector(explorerToggleButtonPressed(_:))

        for button in [historyToggleButton, explorerToggleButton] {
            button.widthAnchor.constraint(equalToConstant: DesignTokens.Component.sidebarToggleSizePX).isActive = true
            button.heightAnchor.constraint(equalToConstant: DesignTokens.Component.sidebarToggleSizePX).isActive = true
        }
        updateSidebarToggleButtonStates()
    }

    /// An open panel keeps its toggle tinted like a selected control so the bar
    /// reads as on/off state, not just as two buttons.
    func updateSidebarToggleButtonStates() {
        for (button, isOpen) in [
            (historyToggleButton, isCommandHistoryPanelVisible),
            (explorerToggleButton, isFileExplorerPanelVisible),
        ] {
            // Everything but the "panel is open" state comes from the theme, so
            // press and focus follow the light ramp under a light theme.
            button.applyChromeTheme(chromeTheme)
            button.normalTintColor = isOpen
                ? chromeTheme.activeIndicator.withAlphaComponent(
                    DesignTokens.Component.sidebarToggleActiveTintAlphaRATIO
                )
                : chromeTheme.textSecondary
            button.normalBackgroundColor = isOpen
                ? chromeTheme.activeIndicator.withAlphaComponent(
                    DesignTokens.Component.sidebarToggleActiveFillAlphaRATIO
                )
                : .clear
            button.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(
                DesignTokens.Component.terminalTabButtonHoverAlphaRATIO
            )
        }
    }

    @objc private func historyToggleButtonPressed(_ sender: NSButton) {
        toggleCommandHistoryPanel()
    }

    @objc private func explorerToggleButtonPressed(_ sender: NSButton) {
        toggleFileExplorerPanel()
    }

    private func makeTabItemView(title: String, index: Int, isSelected: Bool) -> NSView {
        TerminalTabItemView(
            title: title,
            isSelected: isSelected,
            chromeTheme: chromeTheme,
            onSelect: { [weak self] in self?.selectTab(at: index) },
            onClose: { [weak self] in self?.closeTab(at: index) }
        )
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < tabView.numberOfTabViewItems else {
            return
        }
        tabView.selectTabViewItem(at: index)
        updateTabBar()
    }

    private func closeTab(at index: Int) {
        guard index >= 0, index < tabView.numberOfTabViewItems else {
            return
        }
        let item = tabView.tabViewItem(at: index)
        if let coordinator = tmuxCoordinator(managing: item) {
            coordinator.closeWindow(item)
            return
        }
        guard !hasActiveTmuxProjection(hosting: item) else { return }
        guard confirmEditorTabCloseIfNeeded(item) else { return }
        if tabView.numberOfTabViewItems <= 1 {
            // `performClose` runs `windowShouldClose`, which confirms running
            // processes for the whole window; a second tab-level prompt here
            // would ask twice for the same close.
            window?.performClose(nil)
            return
        }
        guard confirmCloseIfRunningProcess(shellProcessIdentifiers: shellProcessIdentifiers(in: item)) else {
            return
        }
        closeTab(tabView.tabViewItem(at: index))
    }

    @objc private func newTabButtonPressed(_ sender: NSButton) {
        newTab()
    }

    private func closeTab(_ item: NSTabViewItem) {
        tabView.removeTabViewItem(item)
        updateTabBar()
        refreshStatusBarPanes()
    }

    fileprivate func tabItem(containing surface: TerminalSurfaceView) -> NSTabViewItem? {
        for index in 0..<tabView.numberOfTabViewItems {
            let item = tabView.tabViewItem(at: index)
            guard let splitView = item.view as? SplitTerminalView else {
                continue
            }
            if splitView.containsTerminalSurface(surface) {
                return item
            }
        }
        return nil
    }

    private var selectedTmuxCoordinator: TmuxNativeSessionCoordinator? {
        guard let item = tabView.selectedTabViewItem else { return nil }
        return tmuxCoordinator(managing: item)
    }

    fileprivate func tmuxCoordinator(managing item: NSTabViewItem) -> TmuxNativeSessionCoordinator? {
        tmuxCoordinators.first { $0.managesTab(item) }
    }

    fileprivate func hasActiveTmuxProjection(hosting item: NSTabViewItem) -> Bool {
        tmuxCoordinators.contains { $0.hostsGateway(in: item) }
    }

    func nativeGroupStartIndex(for coordinator: TmuxNativeSessionCoordinator) -> Int? {
        guard let host = coordinator.visibleGatewayHost,
              let coordinatorIndex = tmuxCoordinators.firstIndex(where: { $0 === coordinator })
        else { return nil }
        let hostIndex = tabView.indexOfTabViewItem(host)
        guard hostIndex != NSNotFound else { return nil }
        let priorGroupSize = tmuxCoordinators[..<coordinatorIndex].reduce(0) { count, candidate in
            guard candidate.visibleGatewayHost === host else { return count }
            return count + candidate.nativeItemCount
        }
        return hostIndex + 1 + priorGroupSize
    }

    func tmuxCoordinatorDidExit(_ coordinator: TmuxNativeSessionCoordinator) {
        tmuxCoordinators.removeAll { $0 === coordinator }
    }

    private func splitView(containing pane: TerminalPaneView) -> SplitTerminalView? {
        for index in 0..<tabView.numberOfTabViewItems {
            guard let splitView = tabView.tabViewItem(at: index).view as? SplitTerminalView,
                  splitView.containsPane(pane)
            else {
                continue
            }
            return splitView
        }
        return nil
    }
}

@MainActor
final class TerminalPaneDropTargetView: NSView {
    var onPaneDrop: (() -> Bool)?
    var onPaneCanDrop: (() -> Bool)?
    var chromeTheme = DesignTokens.ChromeTheme.dark {
        didSet { updateDropAppearance() }
    }

    private var isDropHighlighted = false {
        didSet {
            updateDropAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([TerminalPaneDragCoordinator.pasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [TerminalPaneDragCoordinator.pasteboardType.rawValue]) else {
            return []
        }
        guard onPaneCanDrop?() == true else {
            return []
        }
        isDropHighlighted = true
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onPaneCanDrop?() == true else {
            isDropHighlighted = false
            return []
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropHighlighted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropHighlighted = false
        return onPaneDrop?() == true
    }

    private func updateDropAppearance() {
        layer?.borderWidth = isDropHighlighted ? DesignTokens.Component.paneDropTargetBorderWidthPX : 0
        layer?.borderColor = isDropHighlighted ? DesignTokens.Color.paneDropTargetBorder.cgColor : nil
        layer?.backgroundColor = isDropHighlighted
            ? DesignTokens.Color.paneDropTargetBackground.cgColor
            : chromeTheme.windowBackground.cgColor
    }
}

@MainActor
private final class TerminalTabItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = ChromeIconButton(
        symbolName: IconSymbol.close,
        accessibilityLabel: AppLocalization.string(.closePaneOrTab),
        size: .small,
        target: nil,
        action: nil
    )
    /// Achromatic hover wash painted over whatever the tab's base fill is, so
    /// hover reads the same on the selected and unselected tab and can never be
    /// mistaken for the accent.
    private let hoverOverlayView = NSView()
    /// Selection marker: a 2pt accent rail across the tab's top edge, clipped to
    /// the tab's corner radius.
    private let selectionRailView = NSView()
    private let selected: Bool
    private let chromeTheme: DesignTokens.ChromeTheme
    private var isHovered = false
    private let onSelect: () -> Void
    private let onClose: () -> Void

    init(
        title: String,
        isSelected: Bool,
        chromeTheme: DesignTokens.ChromeTheme,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        selected = isSelected
        self.chromeTheme = chromeTheme
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        configure(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(location) {
            onClose()
            return
        }
        onSelect()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(location) else { return }
        isHovered = false
        updateAppearance()
    }

    @objc private func closePressed(_ sender: NSButton) {
        onClose()
    }

    private func configure(title: String) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // A tab's fill, hover wash, and selection rail all change on the same
        // click that moves it; none of them may fade.
        layer.map(ChromeMotion.disableImplicitAnimations(on:))
        layer?.cornerRadius = DesignTokens.Radius.mdPX
        // Clipping is what lets the top rail stop at the rounded corners instead
        // of overhanging them.
        layer?.masksToBounds = true

        hoverOverlayView.wantsLayer = true
        hoverOverlayView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        hoverOverlayView.isHidden = true
        hoverOverlayView.layer?.backgroundColor = chromeTheme.hoverFill.cgColor
        hoverOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverOverlayView)

        selectionRailView.wantsLayer = true
        selectionRailView.layer.map(ChromeMotion.disableImplicitAnimations(on:))
        selectionRailView.isHidden = !selected
        selectionRailView.layer?.backgroundColor = chromeTheme.accent.cgColor
        selectionRailView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionRailView)

        titleField.stringValue = title
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.applyChromeTheme(chromeTheme)
        // Same deliberate accent hover as the add button.
        closeButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(
            DesignTokens.Component.terminalTabButtonHoverAlphaRATIO
        )
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabHeightPX),
            widthAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.Component.terminalTabMinWidthPX),
            widthAnchor.constraint(lessThanOrEqualToConstant: DesignTokens.Component.terminalTabMaxWidthPX),

            hoverOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hoverOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hoverOverlayView.topAnchor.constraint(equalTo: topAnchor),
            hoverOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

            selectionRailView.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionRailView.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionRailView.topAnchor.constraint(equalTo: topAnchor),
            selectionRailView.heightAnchor.constraint(
                equalToConstant: DesignTokens.Component.terminalTabTopRailHeightPX
            ),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.terminalTabTitleLeadingPX),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -DesignTokens.Component.terminalTabTitleCloseGapPX),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Component.terminalTabCloseTrailingPX),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabCloseWidthPX),
            closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabCloseWidthPX),
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = tabBackgroundColor.cgColor
        hoverOverlayView.isHidden = !isHovered
        let titleRole = selected ? DesignTokens.Typography.tabLabelSel : DesignTokens.Typography.tabLabel
        titleRole.apply(
            to: titleField,
            color: selected || isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary
        )
        closeButton.normalTintColor = selected || isHovered ? chromeTheme.textSecondary : chromeTheme.textTertiary
        closeButton.alphaValue = selected || isHovered ? 1 : 0
    }

    /// The unselected tab has no fill of its own: it sits directly on
    /// `surfaceChrome`, so only the selected tab is raised out of the bar.
    private var tabBackgroundColor: NSColor {
        selected ? chromeTheme.surfaceRaised : .clear
    }
}
