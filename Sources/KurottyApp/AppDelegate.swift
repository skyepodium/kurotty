import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paneDragCoordinator = TerminalPaneDragCoordinator()
    private let updateController = UpdateController()
    private var windowController: TerminalWindowController?
    private var preferencesController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        TerminalNotifier.shared.requestAuthorization()
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

    @objc func openNewWindow() {
        let controller = TerminalWindowController(paneDragCoordinator: paneDragCoordinator)
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

    private func showUpdateUnavailableNotice() {
        let alert = NSAlert()
        alert.messageText = "자동 업데이트를 사용할 수 없습니다"
        alert.informativeText = "이 빌드에는 업데이트 서명이 없어 자동 다운로드와 설치를 시작할 수 없습니다. 정식 배포 빌드에서는 업데이트를 자동으로 내려받고 설치합니다."
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
