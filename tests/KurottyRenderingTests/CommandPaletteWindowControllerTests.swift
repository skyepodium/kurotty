import XCTest
@testable import KurottyApp

final class CommandPaletteWindowControllerTests: XCTestCase {
    func testPresenterFiltersResultsAndResetsSelectionToFirstMatch() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )

        XCTAssertEqual(presenter.visibleEntries.compactMap(\.windowCommand?.id), [
            .newTab,
            .splitVertically,
            .selectNextTab,
        ])
        XCTAssertEqual(presenter.selectedEntry?.windowCommand?.id, .newTab)

        presenter.updateQuery("split")

        XCTAssertEqual(presenter.visibleEntries.compactMap(\.windowCommand?.id), [.splitVertically])
        XCTAssertEqual(presenter.selectedEntry?.windowCommand?.id, .splitVertically)
    }

    func testPresenterClearsSelectionWhenSearchHasNoMatches() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )

        presenter.updateQuery("does-not-exist")

        XCTAssertTrue(presenter.visibleEntries.isEmpty)
        XCTAssertNil(presenter.selectedEntry)
    }

    func testPresenterMovesSelectionWithinVisibleResults() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )

        presenter.moveSelection(by: 1)
        XCTAssertEqual(presenter.selectedEntry?.windowCommand?.id, .splitVertically)

        presenter.moveSelection(by: 10)
        XCTAssertEqual(presenter.selectedEntry?.windowCommand?.id, .selectNextTab)

        presenter.moveSelection(by: -10)
        XCTAssertEqual(presenter.selectedEntry?.windowCommand?.id, .newTab)
    }

    func testPresenterClearsSelectionForInvalidRow() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )

        presenter.select(row: -1)

        XCTAssertNil(presenter.selectedEntry)
    }

    func testPresenterExecutesSelectedCommandThroughProvidedClosure() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )
        var executedIDs: [TerminalWindowCommandID] = []

        presenter.moveSelection(by: 1)
        let didExecute = presenter.executeSelected(
            windowCommandExecutor: { command in
                executedIDs.append(command.id)
            },
            commandSpanExecutor: { _ in false }
        )

        XCTAssertTrue(didExecute)
        XCTAssertEqual(executedIDs, [.splitVertically])
    }

    func testPresenterDoesNotExecuteWhenNoCommandIsSelected() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )
        var executionCount = 0

        presenter.updateQuery("does-not-exist")
        let didExecute = presenter.executeSelected(
            windowCommandExecutor: { _ in
                executionCount += 1
            },
            commandSpanExecutor: { _ in
                executionCount += 1
                return true
            }
        )

        XCTAssertFalse(didExecute)
        XCTAssertEqual(executionCount, 0)
    }

    func testPresenterIncludesCommandSpanActionsAsSelectableRows() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(
                registry: Self.registryWithCommandSpanCommands,
                includesCommandSpanCommands: true
            )
        )

        presenter.updateQuery("search command output")

        XCTAssertEqual(presenter.visibleEntries.compactMap(\.commandSpanCommand?.id), [.searchOutput])
        XCTAssertEqual(presenter.selectedEntry?.title, "Search Command Output")
        XCTAssertEqual(presenter.selectedEntry?.detail, "Command Spans")
    }

    func testPresenterExecutesSelectedCommandSpanThroughSeparateClosure() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(
                registry: Self.registryWithCommandSpanCommands,
                includesCommandSpanCommands: true
            )
        )
        var executedWindowIDs: [TerminalWindowCommandID] = []
        var selectedSpanIDs: [TerminalCommandSpanCommandID] = []

        presenter.updateQuery("rerun command")
        let didExecute = presenter.executeSelected(
            windowCommandExecutor: { command in
                executedWindowIDs.append(command.id)
            },
            commandSpanExecutor: { command in
                selectedSpanIDs.append(command.id)
                return true
            }
        )

        XCTAssertTrue(didExecute)
        XCTAssertTrue(executedWindowIDs.isEmpty)
        XCTAssertEqual(selectedSpanIDs, [.replay])
        XCTAssertEqual(presenter.selectedEntry?.detail, "Command Spans - Requires confirmation")
    }

    func testPresenterDoesNotReportUnhandledCommandSpanAsExecuted() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(
                registry: Self.registryWithCommandSpanCommands,
                includesCommandSpanCommands: true
            )
        )
        var selectedSpanIDs: [TerminalCommandSpanCommandID] = []

        presenter.updateQuery("collapse command output")
        let didExecute = presenter.executeSelected(
            windowCommandExecutor: { _ in },
            commandSpanExecutor: { command in
                selectedSpanIDs.append(command.id)
                return false
            }
        )

        XCTAssertFalse(didExecute)
        XCTAssertEqual(selectedSpanIDs, [.foldOutput])
    }

    private static let registry = TerminalCommandRegistry(windowCommands: [
        command(id: .newTab, title: "New Tab", action: .newTab),
        command(id: .splitVertically, title: "Split Vertically", action: .splitVertically),
        command(id: .selectNextTab, title: "Next Tab", action: .selectNextTab),
    ])

    private static let registryWithCommandSpanCommands = TerminalCommandRegistry(
        windowCommands: registry.windowCommands,
        commandSpanCommands: [
            TerminalCommandSpanCommand(
                id: .foldOutput,
                title: "Fold Command Output",
                subtitle: "Collapse command output.",
                action: .foldOutput,
                searchTokens: ["collapse command output"]
            ),
            TerminalCommandSpanCommand(
                id: .searchOutput,
                title: "Search Command Output",
                subtitle: "Search command output.",
                action: .searchOutput,
                searchTokens: ["find in command output"]
            ),
            TerminalCommandSpanCommand(
                id: .replay,
                title: "Replay Command",
                subtitle: "Replay command after confirmation.",
                action: .replay,
                approvalPolicy: .explicitUserConfirmation,
                searchTokens: ["rerun command"]
            ),
        ]
    )

    private static func command(
        id: TerminalWindowCommandID,
        title: String,
        action: TerminalWindowCommandAction
    ) -> TerminalCommand {
        TerminalCommand(
            id: id,
            title: title,
            category: .tabs,
            shortcut: nil,
            action: action
        )
    }
}
