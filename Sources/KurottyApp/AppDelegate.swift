import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paneDragCoordinator = TerminalPaneDragCoordinator()
    private let updateController = UpdateController()
    private let notificationBridge = KurottyNotificationBridgeServer()
    private var windowController: TerminalWindowController?
    private var commandPaletteController: CommandPaletteWindowController?
    /// Built at launch rather than in a property initializer because its menu
    /// rows target this delegate.
    private var menuBarExtraController: MenuBarExtraController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window: an app running from the DMG cannot update itself,
        // and the offer to move is worth making while the screen is still
        // empty rather than after the user has started working in a terminal.
        AppInstallLocationPrompt.presentIfNeeded()
        installApplicationIcon()
        TerminalNotifier.shared.requestAuthorization()
        notificationBridge.start()
        if DebugOptions.testNotification {
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.Application.initialNotificationDelaySeconds) {
                TerminalNotifier.shared.notifyTestNotification()
            }
        }
        if DebugOptions.seedHistory {
            TerminalCommandHistoryStore.shared.seedInMemoryEntriesForDebugPreview(
                TerminalCommandHistoryDebugSeed.sampleEntries()
            )
        }
        // Before the first window, so the first pane's PTY can already carry the
        // hook variables when the setting is on. A no-op while it is off, and on
        // a fresh install it asks for consent before writing anything.
        AgentStatusHookCoordinator.shared.applyStoredSetting()
        MainMenu.install(target: self)
        installMenuBarExtra()
        openNewWindow()
        // After the first window, so a fresh install lands on Getting Started
        // with a terminal tab already beside it. It is a tab rather than a
        // modal precisely so nothing is blocked: the prompt is one click away
        // and Command-W dismisses the page for good.
        windowController?.openGettingStartedTabOnFirstRunIfNeeded()
        restoreScrollbackFromWorkspaceSnapshot()
        if DebugOptions.showHistoryPanel {
            windowController?.setCommandHistoryPanelVisible(true)
        }
        if DebugOptions.showAgentSessions {
            windowController?.setCommandHistoryPanelVisible(true, section: .agentSessions)
        }
        if DebugOptions.showExplorerPanel {
            windowController?.setFileExplorerPanelVisible(true)
        }
        if let debugEditorPath = DebugOptions.openEditorFilePath {
            windowController?.openEditorTab(for: URL(fileURLWithPath: debugEditorPath))
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        notificationBridge.stop()
        captureWorkspaceSnapshotOnTermination()
    }

    /// Last snapshot of the session. Failures are swallowed — a quit must not be
    /// blocked by an unwritable snapshot — but the pending writes are flushed
    /// so the debounced queue cannot lose the capture to process exit.
    private func captureWorkspaceSnapshotOnTermination() {
        guard let controller = activeTerminalWindowController else {
            return
        }
        _ = try? writeWorkspaceSnapshot(from: controller, to: workspaceSnapshotURL())
        controller.flushScrollbackSnapshotWrites()
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

    /// The menu-bar extra's way back into the app.
    ///
    /// Raises the window that is already open rather than making another one: a
    /// user clicks the extra because Kurotty is behind something else, and
    /// answering that with a second empty window loses them the session they
    /// were looking for. A new window is only correct when there is none —
    /// unlike `focusExistingTerminalWindow`, which is a notification landing on
    /// a window the user is already using and must never create one.
    @objc func openKurotty() {
        NSApp.activate(ignoringOtherApps: true)
        guard let controller = activeTerminalWindowController else {
            showTerminalWindow(makeTerminalWindowController())
            return
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// The extra reads its own setting, so this is a no-op on the default
    /// install: nothing asks `NSStatusBar` for a slot until the user turns it
    /// on. After launch the controller follows the setting on its own.
    private func installMenuBarExtra() {
        let controller = MenuBarExtraController(actionTarget: self)
        menuBarExtraController = controller
        controller.applyStoredSetting()
    }

    /// Settings is a center tab in a terminal window, not a window of its own.
    /// Cmd+, therefore opens or reveals that tab in the window the user is
    /// already looking at, and only makes a window when there is none left to
    /// put it in.
    @objc func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        guard let controller = activeTerminalWindowController else {
            let controller = makeTerminalWindowController()
            showTerminalWindow(controller)
            controller.openSettingsTab()
            return
        }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.openSettingsTab()
    }

    @objc func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preference = AppLanguagePreference(rawValue: rawValue)
        else {
            return
        }
        AppLocalization.preference = preference
        MainMenu.install(target: self)
        menuBarExtraController?.refreshLocalization()
        activeTerminalWindowController?.refreshSettingsTabLocalization()
        activeTerminalWindowController?.refreshGettingStartedTabLocalization()
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
            },
            quickCommandExecutor: { [weak terminalController] command in
                guard let terminalController else {
                    return false
                }
                // Closing the palette is only correct when something was
                // actually written; a refused or empty command leaves it open.
                switch QuickCommandInvoker.invoke(command, target: terminalController) {
                case .insertedText, .executedText:
                    return true
                case .requiresApproval, .emptyCommand:
                    return false
                }
            }
        )
        commandPaletteController = controller
        controller.showWindow(nil)
    }

    @objc func saveWorkspaceSnapshot() {
        guard let terminalController = activeTerminalWindowController else {
            return
        }

        let snapshotURL = workspaceSnapshotURL()
        do {
            _ = try writeWorkspaceSnapshot(from: terminalController, to: snapshotURL)
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

    /// Writes the layout snapshot, capturing each pane's trailing scrollback as
    /// part of the same pass so the snapshot and the referenced files describe
    /// the same moment. Returns the snapshot that was written so callers can
    /// prune against it.
    @discardableResult
    private func writeWorkspaceSnapshot(
        from controller: TerminalWindowController,
        to url: URL
    ) throws -> WorkspaceSnapshot {
        let coordinator = WorkspaceSnapshotCoordinator()
        let descriptor = controller.workspaceDescriptor(capturingScrollback: true)
        let snapshot = coordinator.makeLayoutOnlySnapshot(from: descriptor)
        _ = try coordinator.saveLayoutOnlySnapshot(from: descriptor, to: url)
        controller.pruneScrollbackSnapshots(retaining: snapshot)
        return snapshot
    }

    /// Replays the stored scrollback of the previous session into the panes that
    /// occupy the same layout slots, then prunes anything the restored workspace
    /// no longer references.
    ///
    /// Display-only: nothing here consults or advances the command-replay
    /// opt-in, and no byte reaches a PTY.
    private func restoreScrollbackFromWorkspaceSnapshot() {
        guard let controller = windowController else {
            return
        }
        guard case let .success(snapshot) = WorkspaceSnapshotStore().load(from: workspaceSnapshotURL())
        else {
            return
        }
        controller.restoreScrollback(from: snapshot)
        controller.pruneScrollbackSnapshots(retaining: snapshot)
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

    @objc func toggleCommandHistoryPanel() {
        activeTerminalWindowController?.toggleCommandHistoryPanel()
    }

    @objc func toggleAgentSessionPanel() {
        activeTerminalWindowController?.toggleAgentSessionPanel()
    }

    @objc func toggleFileExplorerPanel() {
        activeTerminalWindowController?.toggleFileExplorerPanel()
    }

    @objc func jumpToPreviousPrompt() {
        activeTerminalWindowController?.jumpToPrompt(.previous)
    }

    @objc func jumpToNextPrompt() {
        activeTerminalWindowController?.jumpToPrompt(.next)
    }

    // The font zoom is app-wide, so unlike the pane and tab commands it stays
    // available with no terminal window key.
    @objc func increaseTerminalFontSize() {
        TerminalFontZoomCoordinator.shared.apply(.increase)
    }

    @objc func decreaseTerminalFontSize() {
        TerminalFontZoomCoordinator.shared.apply(.decrease)
    }

    @objc func resetTerminalFontSize() {
        TerminalFontZoomCoordinator.shared.apply(.reset)
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
            .appendingPathComponent(AppConstants.Workspace.fileName)
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
