import AppKit

final class TerminalWindowController: NSWindowController {
    private let tabView = NSTabView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConstants.Bundle.displayName
        window.center()
        super.init(window: window)
        configureTabs()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    private func currentSplitView() -> SplitTerminalView? {
        tabView.selectedTabViewItem?.view as? SplitTerminalView
    }
}
