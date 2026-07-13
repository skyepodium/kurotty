import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paneDragCoordinator = TerminalPaneDragCoordinator()
    private let updateController = UpdateController()
    private let notificationBridge = KurottyNotificationBridgeServer()
    private var windowController: TerminalWindowController?
    private var preferencesController: PreferencesWindowController?
    private var commandPaletteController: CommandPaletteWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        TerminalNotifier.shared.requestAuthorization()
        notificationBridge.start()
        if DebugOptions.testNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Application.initialNotificationDelaySeconds) {
                TerminalNotifier.shared.notifyTestNotification()
            }
        }
        MainMenu.install(target: self)
        openNewWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        notificationBridge.stop()
    }

    @objc func openNewWindow() {
        showTerminalWindow(makeTerminalWindowController())
    }

    private func makeTerminalWindowController() -> TerminalWindowController {
        let controller = TerminalWindowController(paneDragCoordinator: paneDragCoordinator)
        controller.openCommandPaletteRequested = { [weak self] in
            self?.openCommandPalette()
        }
        return controller
    }

    private func showTerminalWindow(_ controller: TerminalWindowController) {
        controller.showWindow(nil)
        windowController = controller
    }

    @objc func focusExistingTerminalWindow() {
        NSApp.activate(ignoringOtherApps: true)
        activeTerminalWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openPreferences() {
        let controller = preferencesController ?? PreferencesWindowController()
        preferencesController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preference = AppLanguagePreference(rawValue: rawValue)
        else {
            return
        }
        AppLocalization.preference = preference
        MainMenu.install(target: self)
        preferencesController?.refreshLocalization()
        commandPaletteController?.close()
        commandPaletteController = nil
    }

    @objc func openCommandPalette() {
        guard let terminalController = activeTerminalWindowController else {
            return
        }

        let registry = TerminalCommandSpanPaletteActions.registryForPalette(
            commandSpanCommands: terminalController.commandSpanPaletteCommands(),
            registry: terminalController.commandPaletteRegistry()
        )
        let palette = TerminalCommandPalette(registry: registry, includesCommandSpanCommands: true)
        let controller = CommandPaletteWindowController(
            palette: palette,
            commandExecutor: { [weak terminalController] command in
                guard let terminalController else {
                    return
                }
                TerminalCommandDispatcher.execute(command, on: terminalController)
            },
            commandSpanExecutor: { [weak terminalController] command in
                guard let terminalController else {
                    return false
                }
                return terminalController.executeCommandSpanPaletteCommand(command)
            }
        )
        commandPaletteController = controller
        controller.showWindow(nil)
    }

    @objc func saveWorkspaceSnapshot() {
        guard let terminalController = activeTerminalWindowController else {
            return
        }

        let coordinator = WorkspaceSnapshotCoordinator()
        let snapshotURL = workspaceSnapshotURL()
        do {
            let descriptor = terminalController.layoutOnlyWorkspaceDescriptor()
            _ = try coordinator.saveLayoutOnlySnapshot(from: descriptor, to: snapshotURL)
            showInformationalAlert(
                title: "Workspace Saved",
                message: "Saved layout-only workspace snapshot to \(snapshotURL.path)."
            )
        } catch {
            showInformationalAlert(
                title: "Workspace Save Failed",
                message: error.localizedDescription
            )
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if !updateController.isFullyConfigured {
            showUpdateUnavailableNotice()
            return
        }

        updateController.checkForUpdates(sender)
    }

    var canCheckForUpdates: Bool {
        updateController.canCheckForUpdates
    }

    @objc func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppConstants.Bundle.displayName,
            .version: AppConstants.Bundle.displayVersion(bundle: Bundle.main),
        ]
        if let image = NSApp.applicationIconImage ?? loadApplicationIcon()?.image {
            options[.applicationIcon] = image
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
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

    @objc func enterCopyMode() {
        activeTerminalWindowController?.enterCopyMode()
    }

    @objc func openQuickTerminal() {
        guard let controller = activeTerminalWindowController else {
            showTerminalWindow(makeTerminalWindowController())
            return
        }
        controller.openQuickTerminal()
    }

    @objc func findTerminalOutput() {
        activeTerminalWindowController?.findTerminalOutput()
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

    private func workspaceSnapshotURL() -> URL {
        AppSettingsStore.shared.settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("workspace.json")
    }

    private func showUpdateUnavailableNotice() {
        showInformationalAlert(
            title: AppLocalization.string(.updateUnavailableTitle),
            message: AppLocalization.string(.updateUnavailableMessage)
        )
    }

    private func showInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLocalization.string(.ok))
        alert.runModal()
    }

    private func installApplicationIcon() {
        guard let loadedIcon = loadApplicationIcon() else {
            return
        }
        if !loadedIcon.isInstalledIcon {
            // The SwiftPM PNG fallback needs a logical display size. Installed
            // apps must keep the .icns representations intact so Settings,
            // Force Quit, Cmd+Tab, and notification surfaces do not inherit a
            // small runtime-only NSImage size.
            loadedIcon.image.size = NSSize(
                width: AppConstants.Bundle.applicationIconSizePT,
                height: AppConstants.Bundle.applicationIconSizePT
            )
        }
        NSApp.applicationIconImage = loadedIcon.image
    }

    private func loadApplicationIcon() -> (image: NSImage, isInstalledIcon: Bool)? {
        let installedIconURL = Bundle.main.url(
            forResource: AppConstants.Bundle.iconResourceName,
            withExtension: AppConstants.Bundle.installedIconExtension
        )
        if let installedIconURL,
           let image = NSImage(contentsOf: installedIconURL) {
            return (image, true)
        }

        guard let bundledIconURL = KurottyResourceBundle.bundle?.url(
            forResource: AppConstants.Bundle.iconResourceName,
            withExtension: AppConstants.Bundle.iconResourceExtension
        ),
              let image = NSImage(contentsOf: bundledIconURL)
        else {
            return nil
        }
        return (image, false)
    }
}
