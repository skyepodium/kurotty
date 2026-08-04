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
        XCTAssertTrue(explorerSource.contains("surface.workingDirectoryPath"))
        XCTAssertTrue(explorerSource.contains("TerminalSurfaceView.focusDidChangeNotification"))
        XCTAssertTrue(explorerSource.contains("homeDirectoryForCurrentUser"))
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
