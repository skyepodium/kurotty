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
        controller.showWindow(nil)
    }

    @objc func openCommandPalette() {
        guard let terminalController = activeTerminalWindowController else {
            return
        }

        let controller = CommandPaletteWindowController { [weak terminalController] command in
            guard let terminalController else {
                return
            }
            TerminalCommandDispatcher.execute(command, on: terminalController)
        }
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

    @objc func showSearch() {
        activeTerminalWindowController?.showSearch()
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

    @objc func tmuxAttachOrCreateSession() {
        activeTerminalWindowController?.sendTextToActivePane(AppConstants.Tmux.attachOrCreateSessionCommand)
    }

    @objc func tmuxListSessions() {
        activeTerminalWindowController?.sendTextToActivePane(AppConstants.Tmux.listSessionsCommand)
    }

    @objc func tmuxApplyKurottyTheme() {
        activeTerminalWindowController?.sendTextToActivePane(AppConstants.Tmux.applyKurottyThemeCommand)
    }

    @objc func tmuxNewWindow() {
        sendTmuxSequence(AppConstants.Tmux.newWindowSequence)
    }

    @objc func tmuxSplitHorizontally() {
        sendTmuxSequence(AppConstants.Tmux.splitHorizontallySequence)
    }

    @objc func tmuxSplitVertically() {
        sendTmuxSequence(AppConstants.Tmux.splitVerticallySequence)
    }

    @objc func tmuxPreviousWindow() {
        sendTmuxSequence(AppConstants.Tmux.previousWindowSequence)
    }

    @objc func tmuxNextWindow() {
        sendTmuxSequence(AppConstants.Tmux.nextWindowSequence)
    }

    @objc func tmuxDetachClient() {
        sendTmuxSequence(AppConstants.Tmux.detachClientSequence)
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

    private func sendTmuxSequence(_ sequence: String) {
        activeTerminalWindowController?.sendTextToActivePane(sequence)
    }

    private func workspaceSnapshotURL() -> URL {
        AppSettingsStore.shared.settingsURL
            .deletingLastPathComponent()
            .appendingPathComponent("workspace.json")
    }

    private func showUpdateUnavailableNotice() {
        showInformationalAlert(
            title: "자동 업데이트를 사용할 수 없습니다",
            message: "이 빌드에는 업데이트 서명이 없어 자동 다운로드와 설치를 시작할 수 없습니다. 정식 배포 빌드에서는 업데이트를 자동으로 내려받고 설치합니다."
        )
    }

    private func showInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
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

        guard let bundledIconURL = Bundle.module.url(
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
