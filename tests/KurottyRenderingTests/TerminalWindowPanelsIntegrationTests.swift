import AppKit
import XCTest
@testable import KurottyApp

/// Integration coverage for the right file-explorer panel and the center
/// editor tabs: registry/menu/dispatcher wiring, active-pane cwd tracking,
/// editor tab reuse, and the dirty-close confirmation path.
final class TerminalWindowPanelsIntegrationTests: XCTestCase {
    // MARK: - Command registry and shortcuts

    func testToggleExplorerCommandIsRegisteredWithoutShortcutConflicts() throws {
        let commands = TerminalCommandRegistry.default.windowCommands
        let toggleCommand = try XCTUnwrap(
            commands.first { $0.id == .toggleFileExplorerPanel }
        )
        XCTAssertEqual(toggleCommand.id.rawValue, "explorer.togglePanel")
        XCTAssertEqual(toggleCommand.title, "File Explorer")
        XCTAssertEqual(toggleCommand.category, .navigation)
        XCTAssertEqual(toggleCommand.shortcut?.keyEquivalent, "e")
        XCTAssertEqual(toggleCommand.shortcut?.modifiers, [.command, .shift])
        XCTAssertEqual(
            commands.filter { $0.shortcut?.keyEquivalent == "e" }.count,
            1,
            "Cmd+Shift+E must stay unique to the file-explorer toggle"
        )
    }

    func testDispatcherRoutesExplorerToggleToWindowController() throws {
        let dispatcherSource = try sourceFile("Sources/KurottyApp/TerminalCommandDispatcher.swift")
        XCTAssertTrue(dispatcherSource.contains("case .toggleFileExplorerPanel:"))
        XCTAssertTrue(dispatcherSource.contains("controller.toggleFileExplorerPanel()"))
    }

    func testMainMenuExposesFileExplorerToggle() throws {
        let menuSource = try sourceFile("Sources/KurottyApp/MainMenu.swift")
        XCTAssertTrue(menuSource.contains("AppDelegate.toggleFileExplorerPanel"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \"e\""))
    }

    func testExplorerDebugFlagFollowsTheExistingFlagPattern() throws {
        let debugSource = try sourceFile("Sources/KurottyApp/DebugOptions.swift")
        XCTAssertTrue(debugSource.contains("--debug-show-explorer-panel"))
        XCTAssertTrue(debugSource.contains("KUROTTY_DEBUG_SHOW_EXPLORER_PANEL"))

        let appDelegateSource = try sourceFile("Sources/KurottyApp/AppDelegate.swift")
        XCTAssertTrue(appDelegateSource.contains("if DebugOptions.showExplorerPanel"))
        XCTAssertTrue(appDelegateSource.contains("setFileExplorerPanelVisible(true)"))
    }

    // MARK: - Window integration

    @MainActor
    private func makeWindowController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        return TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
    }

    private func makeTemporaryFile(named name: String, contents: String = "hello\n") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-panels-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent(name)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    @MainActor
    func testFileExplorerPanelStartsHiddenAndToggles() {
        let controller = makeWindowController()
        // Leaked controllers keep observing global notifications and
        // destabilize unrelated suites, so close deterministically.
        defer { controller.close() }

        XCTAssertFalse(controller.isFileExplorerPanelVisible)
        controller.toggleFileExplorerPanel()
        XCTAssertTrue(controller.isFileExplorerPanelVisible)
        controller.toggleFileExplorerPanel()
        XCTAssertFalse(controller.isFileExplorerPanelVisible)
    }

    @MainActor
    func testOrthogonalSplitsInheritTheVisibleChromeGround() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let root = try XCTUnwrap(controller.selectedSplitViewForTesting)
        root.applyChromeTheme(.light)
        root.focusFirstPane()

        controller.splitVertically()
        controller.splitHorizontally()

        let splits = allSplitViews(from: root)
        XCTAssertGreaterThan(splits.count, 1, "an orthogonal split must create a nested split")
        for split in splits {
            XCTAssertEqual(
                split.layer?.backgroundColor,
                DesignTokens.ChromeTheme.light.terminalPaneGround.cgColor,
                "a nested split must not expose its default dark ground inside a light window"
            )
        }
    }

    @MainActor
    func testSplitButtonsReceiveTheVisibleChromeTheme() {
        let controller = makeWindowController()
        defer { controller.close() }
        let theme = controller.chromeThemeForTesting

        for button in controller.splitButtonsForTesting {
            XCTAssertEqual(button.normalTintColor, theme.textSecondary)
            XCTAssertEqual(button.hoverTintColor, theme.textPrimary)
            XCTAssertEqual(button.hoverBackgroundColor, theme.hoverFill)
            XCTAssertEqual(button.pressBackgroundColor, theme.pressFill)
        }
    }

    /// A hidden pane must leave the split view entirely: while it merely had
    /// `isHidden` set, the split view kept the pane's last frame and drew a
    /// divider hairline plus an empty strip at the window edge.
    /// Menu items that carry their own action object must survive the
    /// target-rewrite loop in `MainMenu.install`; the app delegate does not
    /// implement their selectors, so a rewritten target disables them.
    func testMainMenuKeepsItemsThatCarryTheirOwnActionTarget() throws {
        let menuSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/KurottyApp/MainMenu.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(menuSource.contains("guard submenuItem.target == nil else { return }"))
        XCTAssertFalse(menuSource.contains("item.submenu?.items.forEach { $0.target = target }"))
    }

    @MainActor
    func testHidingASidebarRemovesItsPaneAndGivesTheWidthBackToTheTerminal() {
        let controller = makeWindowController()
        defer { controller.close() }
        let splitView = controller.commandHistorySplitView
        splitView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

        controller.setCommandHistoryPanelVisible(true)
        controller.setFileExplorerPanelVisible(true)
        splitView.layoutSubtreeIfNeeded()
        XCTAssertTrue(splitView.arrangedSubviews.contains(controller.leftSidebarPanel))
        XCTAssertTrue(splitView.arrangedSubviews.contains(controller.fileExplorerPanel))
        XCTAssertEqual(splitView.arrangedSubviews.count, 3)

        controller.setCommandHistoryPanelVisible(false)
        controller.setFileExplorerPanelVisible(false)
        splitView.layoutSubtreeIfNeeded()

        XCTAssertFalse(
            splitView.arrangedSubviews.contains(controller.leftSidebarPanel),
            "a hidden sidebar must not stay in the split view, or its divider is still drawn"
        )
        XCTAssertFalse(splitView.arrangedSubviews.contains(controller.fileExplorerPanel))
        XCTAssertEqual(
            splitView.arrangedSubviews,
            [controller.terminalContentHostView],
            "only the terminal host may remain, so no divider gap exists"
        )
        XCTAssertEqual(
            controller.terminalContentHostView.frame.width,
            splitView.bounds.width,
            accuracy: 0.5,
            "the terminal must reclaim the full width once both sidebars are hidden"
        )
    }

    /// Re-showing must restore the pane at its default width on the correct
    /// side, since hiding removes it from the split view outright.
    @MainActor
    func testShowingASidebarAgainRestoresItsPaneAtTheCorrectEdge() {
        let controller = makeWindowController()
        defer { controller.close() }
        let splitView = controller.commandHistorySplitView
        splitView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)

        controller.setCommandHistoryPanelVisible(true)
        controller.setFileExplorerPanelVisible(true)
        controller.setCommandHistoryPanelVisible(false)
        controller.setFileExplorerPanelVisible(false)
        controller.setCommandHistoryPanelVisible(true)
        controller.setFileExplorerPanelVisible(true)
        splitView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            splitView.arrangedSubviews,
            [
                controller.fileExplorerPanel,
                controller.terminalContentHostView,
                controller.leftSidebarPanel,
            ],
            "the explorer stays leading and the history panel trailing across toggles"
        )
        XCTAssertGreaterThanOrEqual(
            controller.leftSidebarPanel.frame.width,
            DesignTokens.Component.commandHistoryPanelMinWidthPX
        )
        XCTAssertGreaterThanOrEqual(
            controller.fileExplorerPanel.frame.width,
            DesignTokens.Component.fileExplorerPanelMinWidthPX
        )
    }

    @MainActor
    func testShowingExplorerAdoptsActivePaneWorkingDirectoryWithHomeFallback() {
        let controller = makeWindowController()
        defer { controller.close() }

        controller.setFileExplorerPanelVisible(true)
        XCTAssertEqual(
            controller.fileExplorerPanel.rootDirectory,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
            "an unreported cwd must fall back to the user's home directory"
        )
    }

    @MainActor
    func testHiddenExplorerSkipsRootDirectoryRefresh() {
        let controller = makeWindowController()
        defer { controller.close() }

        controller.refreshFileExplorerRootDirectory()
        XCTAssertNil(
            controller.fileExplorerPanel.rootDirectory,
            "a hidden panel must not pay for directory listings"
        )
    }

    func testWorkingDirectoryChangesFlowThroughTheTitleNotificationPath() throws {
        // OSC 7 publishes through TerminalSurfaceView.titleDidChangeNotification;
        // the controller reuses that signal instead of adding a parallel one.
        let controllerSource = try sourceFile("Sources/KurottyApp/TerminalWindowController.swift")
        let titleHandlerRange = try XCTUnwrap(
            controllerSource.range(of: "func terminalTitleDidChange")
        )
        let handlerTail = controllerSource[titleHandlerRange.lowerBound...]
        XCTAssertTrue(
            handlerTail.contains("refreshFileExplorerRootDirectory()"),
            "cwd tracking must reuse the OSC 7 title publication path"
        )
        XCTAssertTrue(
            controllerSource.contains("refreshFileExplorerRootDirectory()"),
            "tab selection must re-point the explorer at the active pane"
        )

        let explorerSource = try sourceFile("Sources/KurottyApp/TerminalWindowFileExplorer.swift")
        // Re-pointed deliberately: the explorer now receives the pane's full
        // working *location* (path plus remote host) instead of a bare path, so
        // an SSH session lands in the remote empty state.
        XCTAssertTrue(explorerSource.contains("surface.workingDirectoryLocation"))
        XCTAssertTrue(explorerSource.contains("TerminalSurfaceView.focusDidChangeNotification"))
        XCTAssertTrue(explorerSource.contains("homeDirectoryForCurrentUser"))
    }

    // MARK: - Remote working directories

    private enum RemoteFixture {
        static let host = "build-box.example.com"
        static let path = "/srv/app"
        /// `ESC ] 7 ; file://host/path ESC \` — the OSC 7 an SSH-aware shell
        /// integration emits for a directory on another machine.
        static var osc7Sequence: String {
            "\u{1b}]7;file://\(host)\(path)\u{1b}\\"
        }
    }

    /// The full window path, not just the panel: a pane whose OSC 7 directory
    /// lives on another machine must leave the explorer in its remote empty
    /// state and must not list, watch, or `git` anything locally. Before the
    /// location was threaded through, a bare path reached the panel and a
    /// same-named local directory would have been listed instead.
    @MainActor
    func testRemoteWorkingDirectoryLeavesTheExplorerInItsRemoteEmptyState() throws {
        let controller = makeWindowController()
        defer { controller.close() }

        let surface = try XCTUnwrap(controller.currentSplitView()?.activeTerminalSurface())
        surface.consumeTmuxRestoreOutputForTesting(Data(RemoteFixture.osc7Sequence.utf8))
        XCTAssertTrue(
            surface.workingDirectoryLocation.isRemote,
            "the fixture must actually produce a remote OSC 7 location"
        )

        controller.setFileExplorerPanelVisible(true)
        controller.fileExplorerPanel.layoutSubtreeIfNeeded()

        let panel = controller.fileExplorerPanel
        XCTAssertEqual(
            panel.remoteLocation,
            TerminalWorkingDirectoryLocation(path: RemoteFixture.path, remoteHost: RemoteFixture.host)
        )
        XCTAssertNil(panel.rootDirectory, "no local directory may be adopted for a remote session")
        XCTAssertEqual(panel.visibleRowCountForTesting, 0, "a remote session must list nothing locally")
        XCTAssertFalse(panel.isRemoteEmptyStateHiddenForTesting)
        XCTAssertTrue(panel.remoteEmptyStateTextForTesting.contains(RemoteFixture.host))
    }

    /// Replaying a stored command always writes into the *local* pane, so the
    /// confirmation dialog has to say when the entry came from another machine.
    func testReplayConfirmationSurfacesTheHostForRemoteEntries() {
        let remoteText = TerminalCommandHistoryReplay.confirmationInformativeText(
            for: TerminalCommandHistoryEntry(
                commandText: "systemctl restart app",
                cwd: RemoteFixture.path,
                cwdHost: "deploy@\(RemoteFixture.host)",
                exitCode: 0,
                finishedAt: Date()
            )
        )
        XCTAssertTrue(remoteText.hasPrefix("deploy@\(RemoteFixture.host):\(RemoteFixture.path)"))
        XCTAssertTrue(remoteText.contains("systemctl restart app"))

        let localText = TerminalCommandHistoryReplay.confirmationInformativeText(
            for: TerminalCommandHistoryEntry(
                commandText: "swift build",
                cwd: "/Users/tester/dev",
                exitCode: 0,
                finishedAt: Date()
            )
        )
        XCTAssertEqual(localText, "swift build", "a local entry must not gain a host prefix")
    }

    func testReplayDialogUsesTheHostAwareInformativeText() throws {
        let source = try sourceFile("Sources/KurottyApp/TerminalWindowCommandHistory.swift")
        XCTAssertTrue(
            source.contains(
                "alert.informativeText = TerminalCommandHistoryReplay.confirmationInformativeText(for: entry)"
            ),
            "the confirmation alert must show the host-aware text, not the bare command"
        )
    }

    // MARK: - Editor tabs

    @MainActor
    func testOpeningFileAddsEditorTabAndReopeningReusesIt() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let fileURL = try makeTemporaryFile(named: "sample.swift")

        let initialTabCount = controller.tabIdentifiersInOrder.count
        controller.openEditorTab(for: fileURL)
        XCTAssertEqual(controller.tabIdentifiersInOrder.count, initialTabCount + 1)
        XCTAssertEqual(controller.openEditorFileURLs, [fileURL.standardizedFileURL])

        controller.openEditorTab(for: fileURL)
        XCTAssertEqual(
            controller.tabIdentifiersInOrder.count,
            initialTabCount + 1,
            "reopening the same file must select the existing tab, not add one"
        )
    }

    @MainActor
    func testSelectedEditorTabTitlesWindowAndDisablesTerminalOnlyPaths() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let fileURL = try makeTemporaryFile(named: "notes.md")

        controller.openEditorTab(for: fileURL)
        XCTAssertEqual(controller.window?.title, "notes.md")
        XCTAssertNil(
            controller.selectedSplitViewForTesting,
            "an editor tab must not masquerade as a terminal split"
        )

        // Terminal-only commands must be safe no-ops on an editor tab.
        let tabCount = controller.tabIdentifiersInOrder.count
        controller.splitVertically()
        controller.splitHorizontally()
        controller.findTerminalOutput()
        controller.sendTextToActivePane("echo ignored")
        XCTAssertEqual(controller.tabIdentifiersInOrder.count, tabCount)
        XCTAssertEqual(controller.selectedLayoutSlotCount, 0)
    }

    @MainActor
    func testClosingCleanEditorTabNeedsNoConfirmationAndRemovesTab() throws {
        let controller = makeWindowController()
        defer { controller.close() }
        let fileURL = try makeTemporaryFile(named: "clean.txt")

        let initialTabCount = controller.tabIdentifiersInOrder.count
        controller.openEditorTab(for: fileURL)
        controller.closeCurrentTab()
        XCTAssertEqual(controller.tabIdentifiersInOrder.count, initialTabCount)
        XCTAssertTrue(controller.openEditorFileURLs.isEmpty)
    }

    func testEditorTabTitleUsesTabBarModifiedMarker() {
        XCTAssertEqual(
            TerminalEditorTabTitleFormatter.label(fileName: "main.swift", isModified: false),
            "main.swift"
        )
        XCTAssertEqual(
            TerminalEditorTabTitleFormatter.label(fileName: "main.swift", isModified: true),
            "\u{25CF} main.swift"
        )
    }

    func testDirtyCloseDecisionMapsAlertButtonsToSaveDiscardCancel() {
        XCTAssertEqual(
            TerminalEditorTabClosePolicy.decision(for: .alertFirstButtonReturn),
            .saveAndClose
        )
        XCTAssertEqual(
            TerminalEditorTabClosePolicy.decision(for: .alertSecondButtonReturn),
            .discardAndClose
        )
        XCTAssertEqual(
            TerminalEditorTabClosePolicy.decision(for: .alertThirdButtonReturn),
            .cancel
        )
        XCTAssertEqual(TerminalEditorTabClosePolicy.decision(for: .cancel), .cancel)
    }

    func testDirtyEditorTabClosePathIsGatedOnConfirmation() throws {
        // The modal alert cannot run under XCTest, so the wiring is pinned:
        // both tab-close entry points must consult the confirmation gate and
        // the gate must route through the pure close policy.
        let controllerSource = try sourceFile("Sources/KurottyApp/TerminalWindowController.swift")
        XCTAssertEqual(
            controllerSource.components(separatedBy: "guard confirmEditorTabCloseIfNeeded(item) else { return }").count - 1,
            2,
            "both closeCurrentTab and closeTab(at:) must gate on the dirty-editor confirmation"
        )

        let editorTabsSource = try sourceFile("Sources/KurottyApp/TerminalWindowEditorTabs.swift")
        XCTAssertTrue(editorTabsSource.contains("editor.isModified else {"))
        XCTAssertTrue(editorTabsSource.contains("TerminalEditorTabClosePolicy.decision(for: runUnsavedChangesAlert(for: editor))"))
        XCTAssertTrue(editorTabsSource.contains("case .cancel:"))
        XCTAssertTrue(editorTabsSource.contains("editor.save()"))
    }

    // MARK: - Insert path

    func testInsertedExplorerPathsAreShellQuotedWithoutNewline() throws {
        XCTAssertEqual(
            TerminalShellPathQuoting.quoted("/tmp/plain"),
            "'/tmp/plain'"
        )
        XCTAssertEqual(
            TerminalShellPathQuoting.quoted("/tmp/with space/o'brien"),
            "'/tmp/with space/o'\\''brien'"
        )

        let explorerSource = try sourceFile("Sources/KurottyApp/TerminalWindowFileExplorer.swift")
        XCTAssertTrue(
            explorerSource.contains("sendTextToActivePane(TerminalShellPathQuoting.quoted(path))"),
            "insert must send the quoted path through the active-pane path"
        )
        XCTAssertFalse(
            explorerSource.contains("quoted(path) + \"\\n\""),
            "insert must never append a newline"
        )
    }
}

@MainActor
private func allSplitViews(from root: SplitTerminalView) -> [SplitTerminalView] {
    [root] + root.arrangedSubviews.flatMap { subview -> [SplitTerminalView] in
        guard let split = subview as? SplitTerminalView else { return [] }
        return allSplitViews(from: split)
    }
}

private func sourceFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: sourceRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}

/// Both sidebars are removed from the split view while hidden, which destroys
/// any constraint tying them to it. Revealing them has to restore the height
/// pin, or each panel measures its own header-to-list chain and stops partway
/// down the window instead of reaching the status bar.
@MainActor
final class TerminalWindowSidebarPanelHeightTests: XCTestCase {
    private static let contentSize = NSSize(width: 1400, height: 900)

    func testRevealedSidebarPanelsFillTheSplitViewHeight() {
        let controller = makeLaidOutController()
        let splitHeight = controller.commandHistorySplitView.frame.height
        XCTAssertGreaterThan(splitHeight, 0)
        XCTAssertEqual(controller.leftSidebarPanel.frame.height, splitHeight, accuracy: 0.5)
        XCTAssertEqual(controller.fileExplorerPanel.frame.height, splitHeight, accuracy: 0.5)
        XCTAssertEqual(controller.terminalContentHostView.frame.height, splitHeight, accuracy: 0.5)
    }

    func testHidingAndRevealingAPanelKeepsItFullHeight() {
        let controller = makeLaidOutController()
        for _ in 0..<3 {
            controller.setFileExplorerPanelVisible(false)
            controller.setCommandHistoryPanelVisible(false)
            layOut(controller)
            controller.setFileExplorerPanelVisible(true)
            controller.setCommandHistoryPanelVisible(true)
            layOut(controller)
        }
        let splitHeight = controller.commandHistorySplitView.frame.height
        XCTAssertEqual(controller.leftSidebarPanel.frame.height, splitHeight, accuracy: 0.5)
        XCTAssertEqual(controller.fileExplorerPanel.frame.height, splitHeight, accuracy: 0.5)
    }

    private func makeLaidOutController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        let controller = TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        controller.window?.setContentSize(Self.contentSize)
        controller.setCommandHistoryPanelVisible(true)
        controller.setFileExplorerPanelVisible(true)
        layOut(controller)
        return controller
    }

    private func layOut(_ controller: TerminalWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }
}
