import AppKit

@MainActor
final class TerminalWindowController: NSWindowController, NSTabViewDelegate {
    private let dropTargetView = TerminalPaneDropTargetView()
    private let paneDragCoordinator: TerminalPaneDragCoordinator
    private var rootView: NSView {
        dropTargetView
    }
    private let tabBarView = NSView()
    private let tabStackView = NSStackView()
    private let tabView = NSTabView()
    private var tabBarHeightConstraint: NSLayoutConstraint?
    private var chromeTheme: DesignTokens.ChromeTheme

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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: settings.window.width, height: settings.window.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.Bundle.displayName
        window.titlebarAppearsTransparent = true
        window.center()
        super.init(window: window)
        configureTabs(initialPane: initialPane)
        applyChromeTheme(chromeTheme)
        observeSettings()
        observeTerminalTitles()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func newTab() {
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
    }

    func splitVertically() {
        split(direction: .right)
    }

    func splitHorizontally() {
        split(direction: .down)
    }

    func split(direction: TerminalPaneSplitDirection) {
        currentSplitView()?.split(direction: direction)
    }

    func focusPane(_ direction: TerminalPaneFocusDirection) {
        currentSplitView()?.focusPane(direction)
    }

    func sendTextToActivePane(_ text: String) {
        currentSplitView()?.sendTextToActivePane(text)
    }

    func layoutOnlyWorkspaceDescriptor() -> WorkspaceSnapshotCoordinator.WorkspaceDescriptor {
        let windowID = window?.identifier?.rawValue ?? "window-main"
        return WorkspaceSnapshotCoordinator.WorkspaceDescriptor(
            windows: [
                WorkspaceSnapshotCoordinator.WindowDescriptor(
                    id: windowID,
                    title: nil,
                    frame: windowFrameSnapshot,
                    tabs: layoutOnlyTabDescriptors(),
                    activeTabID: selectedTabID
                ),
            ],
            activeWindowID: windowID
        )
    }

    func closeCurrentTab() {
        guard let item = tabView.selectedTabViewItem else {
            return
        }
        if tabView.numberOfTabViewItems <= 1 {
            window?.performClose(nil)
            return
        }
        closeTab(item)
        currentSplitView()?.focusFirstPane()
    }

    func closeCurrentPane() {
        guard currentSplitView()?.closeActivePane() == true else {
            closeCurrentTab()
            return
        }
        currentSplitView()?.focusFirstPane()
    }

    func selectNextTab() {
        guard tabView.numberOfTabViewItems > 1 else {
            return
        }
        tabView.selectNextTabViewItem(nil)
        updateTabBar()
        currentSplitView()?.focusFirstPane()
    }

    func selectPreviousTab() {
        guard tabView.numberOfTabViewItems > 1 else {
            return
        }
        tabView.selectPreviousTabViewItem(nil)
        updateTabBar()
        currentSplitView()?.focusFirstPane()
    }

    private func configureTabs(initialPane: TerminalPaneView?) {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
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
        tabBarView.layer?.backgroundColor = chromeTheme.topChromeBackground.cgColor
        tabBarView.layer?.borderWidth = DesignTokens.Component.hairlinePX
        tabBarView.layer?.borderColor = chromeTheme.borderHairline.cgColor

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
        rootView.addSubview(tabBarView)
        rootView.addSubview(tabView)
        tabBarView.addSubview(tabStackView)

        let tabBarHeightConstraint = tabBarView.heightAnchor.constraint(equalToConstant: 0)
        self.tabBarHeightConstraint = tabBarHeightConstraint
        NSLayoutConstraint.activate([
            tabBarView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tabBarView.topAnchor.constraint(equalTo: rootView.topAnchor),
            tabBarHeightConstraint,

            tabStackView.leadingAnchor.constraint(equalTo: tabBarView.leadingAnchor),
            tabStackView.trailingAnchor.constraint(lessThanOrEqualTo: tabBarView.trailingAnchor),
            tabStackView.topAnchor.constraint(equalTo: tabBarView.topAnchor),
            tabStackView.bottomAnchor.constraint(equalTo: tabBarView.bottomAnchor),

            tabView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            tabView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        addTab(with: initialPane)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        window?.title = tabViewItem?.label ?? AppConstants.Bundle.displayName
        updateTabBar()
        currentSplitView()?.focusFirstPane()
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

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        chromeTheme = DesignTokens.ChromeTheme.theme(for: settings)
        applyChromeTheme(chromeTheme)
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
        tabBarView.layer?.borderColor = chromeTheme.borderHairline.cgColor
        applyChromeThemeToTabSplits(chromeTheme)
        updateTabBar()
    }

    private func applyChromeThemeToTabSplits(_ theme: DesignTokens.ChromeTheme) {
        for index in 0..<tabView.numberOfTabViewItems {
            guard let splitView = tabView.tabViewItem(at: index).view as? SplitTerminalView else {
                continue
            }
            splitView.applyChromeTheme(theme)
        }
    }

    @objc private func terminalTitleDidChange(_ notification: Notification) {
        guard let surface = notification.object as? TerminalSurfaceView,
              let title = notification.userInfo?[TerminalSurfaceView.titleNotificationKey] as? String,
              let item = tabItem(containing: surface)
        else {
            return
        }
        item.label = title
        if item === tabView.selectedTabViewItem {
            window?.title = title
        }
        updateTabBar()
    }

    private func currentSplitView() -> SplitTerminalView? {
        tabView.selectedTabViewItem?.view as? SplitTerminalView
    }

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

    private func layoutOnlyTabDescriptors() -> [WorkspaceSnapshotCoordinator.TabDescriptor] {
        (0..<tabView.numberOfTabViewItems).compactMap { index in
            let item = tabView.tabViewItem(at: index)
            guard let splitView = item.view as? SplitTerminalView else {
                return nil
            }
            return WorkspaceSnapshotCoordinator.TabDescriptor(
                id: tabID(for: item, index: index),
                title: nil,
                root: splitView.layoutOnlyDescriptor(idPrefix: "tab-\(index)")
            )
        }
    }

    private func tabID(for item: NSTabViewItem, index: Int) -> String {
        if let id = item.identifier as? String, !id.isEmpty {
            return id
        }
        return "tab-\(index)"
    }

    private func defaultTabLabel() -> String {
        "~ (-zsh)"
    }

    private func updateTabBar() {
        tabBarHeightConstraint?.constant = tabView.numberOfTabViewItems > 1
            ? DesignTokens.Component.terminalTabBarHeightPX
            : 0
        tabBarView.isHidden = tabView.numberOfTabViewItems <= 1

        tabStackView.arrangedSubviews.forEach { view in
            tabStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for index in 0..<tabView.numberOfTabViewItems {
            let item = tabView.tabViewItem(at: index)
            let tabItemView = makeTabItemView(title: item.label, index: index, isSelected: item === tabView.selectedTabViewItem)
            tabStackView.addArrangedSubview(tabItemView)
        }

        let addButton = ChromeIconButton(title: "+", target: self, action: #selector(newTabButtonPressed(_:)))
        addButton.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .semibold)
        addButton.normalTintColor = chromeTheme.textSecondary
        addButton.hoverTintColor = chromeTheme.textPrimary
        addButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(0.18)
        addButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabPlusWidthPX).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabHeightPX).isActive = true
        tabStackView.addArrangedSubview(addButton)
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
        if tabView.numberOfTabViewItems <= 1 {
            window?.performClose(nil)
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
    }

    private func tabItem(containing surface: TerminalSurfaceView) -> NSTabViewItem? {
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
    private let closeButton = ChromeIconButton(title: "×", target: nil, action: nil)
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
        isHovered = false
        updateAppearance()
    }

    @objc private func closePressed(_ sender: NSButton) {
        onClose()
    }

    private func configure(title: String) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Component.terminalTabCornerRadiusPX
        layer?.borderWidth = selected ? DesignTokens.Component.terminalTabBorderWidthPX : 0
        layer?.borderColor = chromeTheme.borderHairline.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = NSSize(width: 0, height: DesignTokens.Component.terminalTabShadowOffsetYPX)
        layer?.shadowRadius = selected ? DesignTokens.Component.terminalTabShadowRadiusPX : 0
        layer?.shadowOpacity = selected ? DesignTokens.Component.terminalTabShadowOpacity : 0

        let selectedBar = NSView()
        selectedBar.translatesAutoresizingMaskIntoConstraints = false
        selectedBar.wantsLayer = true
        selectedBar.layer?.backgroundColor = selected
            ? chromeTheme.activeIndicator.cgColor
            : NSColor.clear.cgColor
        selectedBar.layer?.cornerRadius = DesignTokens.Component.hairlinePX
        addSubview(selectedBar)

        titleField.stringValue = title
        titleField.font = selected
            ? NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .semibold)
            : NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .regular)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        closeButton.normalTintColor = selected ? chromeTheme.textSecondary : chromeTheme.textMuted
        closeButton.hoverTintColor = chromeTheme.textPrimary
        closeButton.hoverBackgroundColor = chromeTheme.activeIndicator.withAlphaComponent(0.18)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabHeightPX),
            widthAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.Component.terminalTabMinWidthPX),
            widthAnchor.constraint(lessThanOrEqualToConstant: DesignTokens.Component.terminalTabMaxWidthPX),

            selectedBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Component.terminalTabSelectedBarInsetPX),
            selectedBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Component.terminalTabSelectedBarInsetPX),
            selectedBar.topAnchor.constraint(equalTo: topAnchor),
            selectedBar.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabSelectedBarHeightPX),

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
        titleField.textColor = selected || isHovered ? chromeTheme.textPrimary : chromeTheme.textSecondary
        closeButton.normalTintColor = selected || isHovered ? chromeTheme.textSecondary : chromeTheme.textMuted
    }

    private var tabBackgroundColor: NSColor {
        if selected {
            return isHovered ? chromeTheme.activeTabBackground.blended(withFraction: 0.10, of: DesignTokens.Color.accentBlue) ?? chromeTheme.activeTabBackground : chromeTheme.activeTabBackground
        }
        return isHovered
            ? chromeTheme.inactiveTabHoverBackground
            : chromeTheme.inactiveTabBackground
    }
}
