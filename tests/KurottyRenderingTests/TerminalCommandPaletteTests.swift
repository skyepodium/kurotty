import XCTest
@testable import KurottyApp

final class TerminalCommandPaletteTests: XCTestCase {
    func testEmptyQueryReturnsDefaultVisibleCommandsInRegistryOrder() {
        let palette = TerminalCommandPalette()

        XCTAssertEqual(
            palette.results(for: "").map(\.command.id),
            TerminalCommandRegistry.default.windowCommands.map(\.id)
        )
        XCTAssertEqual(
            palette.results(for: "   ").map(\.command.id),
            TerminalCommandRegistry.default.windowCommands.map(\.id)
        )
    }

    func testSearchRanksTitlePrefixBeforeContainsAndIDMatches() {
        let palette = TerminalCommandPalette(registry: TerminalCommandRegistry(windowCommands: [
            Self.command(id: .splitHorizontally, title: "Horizontal Pane", category: .navigation),
            Self.command(id: .newTab, title: "Open Split History", category: .tabs),
            Self.command(id: .splitVertically, title: "Split Vertically", category: .panes),
        ]))

        let resultIDs: [TerminalWindowCommandID] = palette.results(for: "split").map(\.command.id)
        XCTAssertEqual(
            resultIDs,
            [.splitVertically, .newTab, .splitHorizontally]
        )
    }

    func testSearchMatchesFuzzyTokensAliasesAndCategory() {
        let palette = TerminalCommandPalette()

        XCTAssertEqual(palette.results(for: "nxt tb").first?.command.id, .selectNextTab)
        XCTAssertEqual(palette.results(for: "vertical split").first?.command.id, .splitVertically)

        let paneIDs = palette.results(for: "panes").map(\.command.id)
        XCTAssertTrue(paneIDs.contains(.splitVertically))
        XCTAssertTrue(paneIDs.contains(.splitHorizontally))
        XCTAssertTrue(paneIDs.contains(.closeCurrentPane))
    }

    func testCategoryFilteringAppliesToEmptyAndNonEmptyQueries() {
        let palette = TerminalCommandPalette()

        XCTAssertEqual(
            palette.results(for: "", category: .panes).map(\.command.id),
            [.splitVertically, .splitHorizontally, .closeCurrentPane]
        )
        XCTAssertEqual(
            palette.results(for: "tab", category: .navigation).map(\.command.id),
            [.selectPreviousTab, .selectNextTab]
        )
    }

    func testShortcutDisplayLabelsAreSearchable() {
        let palette = TerminalCommandPalette()
        let entriesByID = Dictionary(uniqueKeysWithValues: palette.entries.map { ($0.command.id, $0) })

        XCTAssertEqual(entriesByID[.newTab]?.shortcutLabel, "⌘T")
        XCTAssertEqual(entriesByID[.splitHorizontally]?.shortcutLabel, "⇧⌘D")
        XCTAssertEqual(entriesByID[.focusPaneLeft]?.shortcutLabel, "⌘←")

        XCTAssertEqual(palette.results(for: "⌘T").first?.command.id, .newTab)
        XCTAssertEqual(palette.results(for: "⇧⌘D").first?.command.id, .splitHorizontally)
        XCTAssertEqual(palette.results(for: "⌘←").first?.command.id, .focusPaneLeft)
    }

    func testPaletteCommandIDsAreUnique() {
        let ids = TerminalCommandPalette().entries.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }

    private static func command(
        id: TerminalWindowCommandID,
        title: String,
        category: TerminalCommandCategory
    ) -> TerminalCommand {
        TerminalCommand(
            id: id,
            title: title,
            category: category,
            shortcut: nil,
            action: .newTab
        )
    }
}
