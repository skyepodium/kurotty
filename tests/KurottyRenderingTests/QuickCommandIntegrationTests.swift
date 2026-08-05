import AppKit
import XCTest
@testable import KurottyApp

/// Wiring coverage for the four entry points quick commands were given: the
/// window controller as the one `QuickCommandSendTarget`, the command palette,
/// the terminal context menu, and the menu item / Preferences button.
///
/// The feature's own behavior (normalization, scoping, dispatch approval) is
/// covered by `QuickCommandTests`; everything here is about the seams.
final class QuickCommandIntegrationTests: XCTestCase {
    private enum Fixture {
        static let repositoryPath = "/Users/tester/dev/terminal/kurotty"
        static let insertIdentifier = "integration-insert"
        static let executeIdentifier = "integration-execute"
        static let insertName = "Status"
        static let executeName = "Build"
        static let statusCommand = "git status"
        static let buildCommand = "swift build"
        /// `ESC ] 7 ; file:///path ESC \` for a directory on this Mac.
        static var localOsc7Sequence: String {
            "\u{1b}]7;file://localhost\(repositoryPath)\u{1b}\\"
        }
    }

    private func makeCommands() -> [QuickCommand] {
        [
            QuickCommand(
                id: Fixture.insertIdentifier,
                name: Fixture.insertName,
                action: .terminalCommand(text: Fixture.statusCommand, appendEnter: false)
            ),
            QuickCommand(
                id: Fixture.executeIdentifier,
                name: Fixture.executeName,
                action: .terminalCommand(text: Fixture.buildCommand, appendEnter: true)
            ),
        ]
    }

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

    // MARK: - Send target

    /// The controller is the only object allowed to write a quick command into
    /// a pane, and it may only be reached through `QuickCommandInvoker`.
    @MainActor
    func testWindowControllerIsTheSendTargetAndReportsTheActivePaneDirectory() throws {
        let controller = makeWindowController()
        defer { controller.close() }

        XCTAssertNotNil(controller as QuickCommandSendTarget)

        let surface = try XCTUnwrap(controller.currentSplitView()?.activeTerminalSurface())
        surface.consumeTmuxRestoreOutputForTesting(Data(Fixture.localOsc7Sequence.utf8))

        XCTAssertEqual(controller.quickCommandWorkingDirectory, Fixture.repositoryPath)
    }

    /// Insert-only commands write their text without a trailing Return, so
    /// nothing runs until the user presses it.
    @MainActor
    func testInvokerWritesInsertOnlyTextWithoutARunningNewline() {
        var written: [String] = []
        let target = QuickCommandClosureSendTarget(
            workingDirectory: { Fixture.repositoryPath },
            sendText: { written.append($0) }
        )

        let result = QuickCommandInvoker.invoke(makeCommands()[0], target: target)

        XCTAssertEqual(result, .insertedText(Fixture.statusCommand))
        XCTAssertEqual(written, [Fixture.statusCommand])
    }

    @MainActor
    func testSendTargetConformanceRefocusesThePaneAfterWriting() throws {
        let source = try quickCommandSource("Sources/KurottyApp/TerminalWindowQuickCommands.swift")
        XCTAssertTrue(source.contains("extension TerminalWindowController: QuickCommandSendTarget"))
        XCTAssertTrue(source.contains("sendTextToActivePane(text)"))
        XCTAssertTrue(source.contains("currentSplitView()?.focusFirstPane()"))
        XCTAssertTrue(
            source.contains("QuickCommandInvoker.invoke(command, target: self)"),
            "id resolution must route through the invoker, never straight to the pane"
        )
    }

    // MARK: - Command palette

    @MainActor
    func testPaletteRegistryCarriesTheActivePanesQuickCommands() throws {
        let registry = TerminalCommandRegistry.default.registering(
            quickCommands: makeCommands(),
            workingDirectory: Fixture.repositoryPath,
            language: .english
        )

        XCTAssertEqual(registry.quickCommands.count, 2)
        XCTAssertEqual(registry.quickCommand(for: Fixture.insertIdentifier)?.name, Fixture.insertName)

        // The palette hand-off must not drop them while swapping in the
        // selection's command-span commands.
        let paletteRegistry = TerminalCommandSpanPaletteActions.registryForPalette(
            commandSpanCommands: [],
            registry: registry
        )
        XCTAssertEqual(paletteRegistry.quickCommands.count, 2)
    }

    @MainActor
    func testPaletteRendersQuickCommandsAsATrailingSectionAndExecutesThem() throws {
        let registry = TerminalCommandRegistry.default.registering(
            quickCommands: makeCommands(),
            workingDirectory: Fixture.repositoryPath,
            language: .english
        )
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: registry, includesCommandSpanCommands: true),
            language: .english
        )

        presenter.updateQuery(Fixture.executeName)
        let quickCommandIndex = try XCTUnwrap(
            presenter.visibleEntries.firstIndex { $0.quickCommand?.id == Fixture.executeIdentifier }
        )
        presenter.select(row: quickCommandIndex)

        let entry = try XCTUnwrap(presenter.selectedEntry)
        XCTAssertEqual(entry.title, Fixture.executeName)
        XCTAssertEqual(
            entry.detail,
            "Quick Commands - " + AppLocalization.string(.quickCommandRunsImmediately, language: .english),
            "an executing quick command must be marked as such in the palette row"
        )

        var executed: [String] = []
        let didExecute = presenter.executeSelected(
            windowCommandExecutor: { _ in XCTFail("a quick command must not run as a window command") },
            commandSpanExecutor: { _ in
                XCTFail("a quick command must not run as a command-span command")
                return false
            },
            quickCommandExecutor: { command in
                executed.append(command.id)
                return true
            }
        )

        XCTAssertTrue(didExecute)
        XCTAssertEqual(executed, [Fixture.executeIdentifier])
    }

    func testWindowControllerBuildsThePaletteRegistryWithQuickCommands() throws {
        let source = try quickCommandSource("Sources/KurottyApp/TerminalWindowController.swift")
        XCTAssertTrue(source.contains("registry.registering("))
        XCTAssertTrue(source.contains("QuickCommandStore.shared.commands(forWorkingDirectory: workingDirectory)"))
    }

    // MARK: - Context menu

    @MainActor
    func testContextMenuLayoutAppendsAQuickCommandsSubmenuCarryingIdentifiers() throws {
        let layout = TerminalContextMenuBuilder.layout(
            for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: true),
            quickCommands: makeCommands(),
            workingDirectory: Fixture.repositoryPath,
            language: .english
        )

        XCTAssertEqual(
            layout.entries,
            TerminalContextMenuBuilder.entries(
                for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: true),
                language: .english
            ),
            "the flat entries must stay exactly what the surface already renders"
        )

        let submenu = try XCTUnwrap(layout.quickCommandSubmenu)
        let menu = QuickCommandContextMenuBuilder.makeMenu(
            for: submenu,
            target: self,
            action: #selector(quickCommandMenuActionForTesting(_:))
        )
        XCTAssertEqual(menu.items.map { $0.representedObject as? String },
                       [Fixture.insertIdentifier, Fixture.executeIdentifier])
    }

    /// Nothing visible for this directory means no submenu at all, so the menu
    /// never grows an empty "Quick Commands" entry.
    @MainActor
    func testContextMenuOmitsTheSubmenuWhenNothingIsVisible() {
        let layout = TerminalContextMenuBuilder.layout(
            for: TerminalContextMenuState(hasSelection: false, hasPasteboardText: false),
            quickCommands: [],
            workingDirectory: Fixture.repositoryPath,
            language: .english
        )
        XCTAssertNil(layout.quickCommandSubmenu)
    }

    func testSurfaceRendersTheSubmenuWithoutExtendingTheFixedActionEnum() throws {
        let contextMenuSource = try quickCommandSource("Sources/KurottyApp/TerminalContextMenu.swift")
        XCTAssertFalse(
            contextMenuSource.contains("case quickCommand"),
            "TerminalContextMenuAction is switched exhaustively and must stay closed"
        )

        let surfaceSource = try quickCommandSource("Sources/KurottyApp/TerminalSurfaceView.swift")
        XCTAssertTrue(surfaceSource.contains("TerminalContextMenuBuilder.layout("))
        XCTAssertTrue(surfaceSource.contains("QuickCommandContextMenuBuilder.makeMenu("))
        XCTAssertTrue(surfaceSource.contains("sender.representedObject as? String"))
        XCTAssertTrue(surfaceSource.contains("controller.invokeQuickCommand(withID: quickCommandID)"))
    }

    @objc private func quickCommandMenuActionForTesting(_ sender: NSMenuItem) {}

    // MARK: - Menu item, shortcut, Preferences

    func testMenuItemUsesCommandShiftKAndTheShortcutIsUnclaimed() throws {
        let menuSource = try quickCommandSource("Sources/KurottyApp/MainMenu.swift")
        XCTAssertTrue(menuSource.contains("QuickCommandsMenuActionTarget.showQuickCommandsEditor"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \"K\""))
        XCTAssertTrue(menuSource.contains("QuickCommandsMenuActionTarget.shared"))

        XCTAssertTrue(
            TerminalCommandRegistry.localizedTmuxControl.windowCommands.allSatisfy {
                $0.shortcut?.keyEquivalent?.lowercased() != "k"
            },
            "Cmd+Shift+K must not collide with a registered window command"
        )
    }

    func testPreferencesOffersTheQuickCommandsEditorButton() throws {
        // PreferencesView was split; the button title lives in the panes file
        // and its action handler in the view file.
        let preferencesSource = try quickCommandSource("Sources/KurottyApp/PreferencesView.swift")
            + quickCommandSource("Sources/KurottyApp/PreferencesViewPanes.swift")
        XCTAssertTrue(preferencesSource.contains("QuickCommandsEditorPresenter.presentQuickCommandsEditor()"))
        XCTAssertTrue(preferencesSource.contains("copy(.quickCommandsButtonTitle)"))
    }
}

private func quickCommandSource(_ relativePath: String) throws -> String {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        root.deleteLastPathComponent()
    }
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}
