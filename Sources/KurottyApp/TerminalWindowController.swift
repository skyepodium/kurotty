import AppKit

@MainActor
final class TerminalWindowController: NSWindowController, NSTabViewDelegate {
    private let rootView = NSView()
    private let tabBarView = NSView()
    private let tabStackView = NSStackView()
    private let tabView = NSTabView()
    private var tabBarHeightConstraint: NSLayoutConstraint?

    init() {
        let settings = (try? AppSettingsStore.shared.load()) ?? .default
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: settings.window.width, height: settings.window.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.Bundle.displayName
        window.center()
        super.init(window: window)
        configureTabs()
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
        let identifier = UUID().uuidString
        let splitView = SplitTerminalView(axis: .vertical)
        let item = NSTabViewItem(identifier: identifier)
        item.label = defaultTabLabel()
        item.view = splitView
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        updateTabBar()
        currentSplitView()?.focusFirstPane()
    }

    func splitVertically() {
        currentSplitView()?.split(axis: .vertical)
    }

    func splitHorizontally() {
        currentSplitView()?.split(axis: .horizontal)
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

    private func configureTabs() {
        rootView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = rootView

        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        tabBarView.wantsLayer = true
        tabBarView.layer?.backgroundColor = NSColor(calibratedWhite: 0.88, alpha: 1).cgColor

        tabStackView.orientation = .horizontal
        tabStackView.alignment = .centerY
        tabStackView.spacing = 3
        tabStackView.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 3, right: 6)
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
        newTab()
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
        window?.setContentSize(NSSize(width: settings.window.width, height: settings.window.height))
        window?.center()
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

        let addButton = NSButton(title: "+", target: self, action: #selector(newTabButtonPressed(_:)))
        addButton.bezelStyle = .regularSquare
        addButton.isBordered = false
        addButton.setButtonType(.momentaryPushIn)
        addButton.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .semibold)
        addButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabPlusWidthPX).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabBarHeightPX - 9).isActive = true
        tabStackView.addArrangedSubview(addButton)
    }

    private func makeTabItemView(title: String, index: Int, isSelected: Bool) -> NSView {
        TerminalTabItemView(
            title: title,
            isSelected: isSelected,
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
}

@MainActor
private final class TerminalTabItemView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let selected: Bool
    private var isHovered = false
    private let onSelect: () -> Void
    private let onClose: () -> Void

    init(title: String, isSelected: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        selected = isSelected
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        configure(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
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
        layer?.cornerRadius = 7
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = NSColor(calibratedWhite: 0.78, alpha: 1).cgColor

        let selectedBar = NSView()
        selectedBar.translatesAutoresizingMaskIntoConstraints = false
        selectedBar.wantsLayer = true
        selectedBar.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        selectedBar.layer?.cornerRadius = 1
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
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: DesignTokens.Typography.labelFontSizePT, weight: .medium)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabBarHeightPX - 8),
            widthAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.Component.terminalTabMinWidthPX),
            widthAnchor.constraint(lessThanOrEqualToConstant: DesignTokens.Component.terminalTabMaxWidthPX),

            selectedBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            selectedBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            selectedBar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectedBar.heightAnchor.constraint(equalToConstant: 2),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabCloseWidthPX),
            closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.Component.terminalTabBarHeightPX - 10),
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = tabBackgroundColor.cgColor
        titleField.textColor = selected || isHovered ? .labelColor : .secondaryLabelColor
        closeButton.contentTintColor = selected || isHovered ? .labelColor : .tertiaryLabelColor
    }

    private var tabBackgroundColor: NSColor {
        if selected {
            return isHovered ? NSColor(calibratedWhite: 0.98, alpha: 1) : .white
        }
        return isHovered
            ? NSColor(calibratedWhite: 0.96, alpha: 1)
            : NSColor(calibratedWhite: 0.92, alpha: 1)
    }
}
