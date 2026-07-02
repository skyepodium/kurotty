import XCTest
@testable import KurottyApp

final class CommandPaletteWindowControllerTests: XCTestCase {
    func testPresenterFiltersResultsAndResetsSelectionToFirstMatch() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )

        XCTAssertEqual(presenter.visibleEntries.map(\.command.id), [
            .newTab,
            .splitVertically,
            .selectNextTab,
        ])
        XCTAssertEqual(presenter.selectedEntry?.command.id, .newTab)

        presenter.updateQuery("split")

        XCTAssertEqual(presenter.visibleEntries.map(\.command.id), [.splitVertically])
        XCTAssertEqual(presenter.selectedEntry?.command.id, .splitVertically)
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
        XCTAssertEqual(presenter.selectedEntry?.command.id, .splitVertically)

        presenter.moveSelection(by: 10)
        XCTAssertEqual(presenter.selectedEntry?.command.id, .selectNextTab)

        presenter.moveSelection(by: -10)
        XCTAssertEqual(presenter.selectedEntry?.command.id, .newTab)
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
        let didExecute = presenter.executeSelected { command in
            executedIDs.append(command.id)
        }

        XCTAssertTrue(didExecute)
        XCTAssertEqual(executedIDs, [.splitVertically])
    }

    func testPresenterDoesNotExecuteWhenNoCommandIsSelected() {
        var presenter = CommandPalettePresenter(
            palette: TerminalCommandPalette(registry: Self.registry)
        )
        var executionCount = 0

        presenter.updateQuery("does-not-exist")
        let didExecute = presenter.executeSelected { _ in
            executionCount += 1
        }

        XCTAssertFalse(didExecute)
        XCTAssertEqual(executionCount, 0)
    }

    private static let registry = TerminalCommandRegistry(windowCommands: [
        command(id: .newTab, title: "New Tab", action: .newTab),
        command(id: .splitVertically, title: "Split Vertically", action: .splitVertically),
        command(id: .selectNextTab, title: "Next Tab", action: .selectNextTab),
    ])

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
