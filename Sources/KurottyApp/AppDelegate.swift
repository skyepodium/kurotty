import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: TerminalWindowController?
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        MainMenu.install(target: self)
        openNewWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openNewWindow() {
        let controller = TerminalWindowController()
        controller.showWindow(nil)
        windowController = controller
    }

    @objc func openPreferences() {
        let controller = preferencesController ?? PreferencesWindowController()
        preferencesController = controller
        controller.showWindow(nil)
    }

    @objc func newTab() {
        activeTerminalWindowController?.newTab()
    }

    @objc func closeCurrentTab() {
        activeTerminalWindowController?.closeCurrentTab()
    }

    @objc func closeCurrentPane() {
        activeTerminalWindowController?.closeCurrentPane()
    }

    @objc func selectNextTab() {
        activeTerminalWindowController?.selectNextTab()
    }

    @objc func selectPreviousTab() {
        activeTerminalWindowController?.selectPreviousTab()
    }

    @objc func splitVertically() {
        activeTerminalWindowController?.splitVertically()
    }

    @objc func splitHorizontally() {
        activeTerminalWindowController?.splitHorizontally()
    }

    private var activeTerminalWindowController: TerminalWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? TerminalWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? TerminalWindowController {
            return controller
        }
        return windowController
    }

    private func installApplicationIcon() {
        guard let url = Bundle.module.url(
            forResource: AppConstants.Bundle.iconResourceName,
            withExtension: AppConstants.Bundle.iconResourceExtension
        ),
              let image = NSImage(contentsOf: url)
        else {
            return
        }
        image.size = NSSize(
            width: AppConstants.Bundle.applicationIconSizePT,
            height: AppConstants.Bundle.applicationIconSizePT
        )
        NSApp.applicationIconImage = image
    }
}
