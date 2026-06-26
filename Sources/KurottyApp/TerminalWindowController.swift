import AppKit

@MainActor
final class TerminalWindowController: NSWindowController {
    private let tabView = NSTabView()

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func newTab() {
        let item = NSTabViewItem(identifier: UUID().uuidString)
        item.label = "Terminal \(tabView.numberOfTabViewItems + 1)"
        item.view = SplitTerminalView(axis: .vertical)
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
    }

    func splitVertically() {
        currentSplitView()?.split(axis: .vertical)
    }

    func splitHorizontally() {
        currentSplitView()?.split(axis: .horizontal)
    }

    private func configureTabs() {
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        tabView.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView = tabView
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor),
        ])
        newTab()
    }

    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: AppSettingsStore.shared,
        )
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        guard let settings = notification.userInfo?[AppSettingsStore.notificationSettingsKey] as? AppSettings else {
            return
        }
        window?.setContentSize(NSSize(width: settings.window.width, height: settings.window.height))
        window?.center()
    }

    private func currentSplitView() -> SplitTerminalView? {
        tabView.selectedTabViewItem?.view as? SplitTerminalView
    }
}
