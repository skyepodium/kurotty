import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: TerminalWindowController?
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        windowController?.newTab()
    }

    @objc func splitVertically() {
        windowController?.splitVertically()
    }

    @objc func splitHorizontally() {
        windowController?.splitHorizontally()
    }
}
