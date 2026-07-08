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

    func testSearchMatchesCommonNonDeveloperActionPhrases() {
        let palette = TerminalCommandPalette()

        XCTAssertEqual(palette.results(for: "open another tab").first?.command.id, .newTab)
        XCTAssertEqual(palette.results(for: "side by side").first?.command.id, .splitVertically)
        XCTAssertEqual(palette.results(for: "stacked panes").first?.command.id, .splitHorizontally)
        XCTAssertEqual(palette.results(for: "close window").first?.command.id, .closeCurrentPane)
        XCTAssertEqual(palette.results(for: "forward tab").first?.command.id, .selectNextTab)
        XCTAssertEqual(palette.results(for: "back tab").first?.command.id, .selectPreviousTab)
    }

    func testCommandSearchTokensAreExposedOnPaletteEntries() {
        let palette = TerminalCommandPalette()
        let entriesByID = Dictionary(uniqueKeysWithValues: palette.entries.map { ($0.command.id, $0) })

        XCTAssertTrue(entriesByID[.newTab]?.aliases.contains("open another tab") == true)
        XCTAssertTrue(entriesByID[.splitVertically]?.aliases.contains("side by side") == true)
        XCTAssertTrue(entriesByID[.closeCurrentPane]?.aliases.contains("close window") == true)
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

    func testCommandSpanCommandsCanBeSearchedFromRegistryBackedPalette() {
        let palette = TerminalCommandPalette(includesCommandSpanCommands: true)

        XCTAssertEqual(
            palette.commandSpanResults(for: "rerun command").first?.command.id,
            .replay
        )
        XCTAssertEqual(
            palette.commandSpanResults(for: "copy span reference").first?.command.id,
            .copyReference
        )
        XCTAssertEqual(
            palette.commandSpanResults(for: "").map(\.command.id),
            TerminalCommandRegistry.default.commandSpanCommands.map(\.id)
        )
    }

    func testCommandSpanPaletteEntriesExposeUXReadinessMetadata() {
        let palette = TerminalCommandPalette(includesCommandSpanCommands: true)
        let entriesByID = Dictionary(uniqueKeysWithValues: palette.commandSpanEntries.map { ($0.command.id, $0) })

        XCTAssertEqual(
            entriesByID[.foldOutput]?.subtitle,
            "Collapse a completed command's output while keeping the command reference."
        )
        XCTAssertEqual(
            entriesByID[.searchOutput]?.subtitle,
            "Search within a completed command's output range."
        )
        XCTAssertEqual(
            entriesByID[.replay]?.subtitle,
            "Run the captured command again after explicit confirmation."
        )
        XCTAssertFalse(entriesByID[.foldOutput]?.requiresExplicitApproval == true)
        XCTAssertTrue(entriesByID[.replay]?.requiresExplicitApproval == true)
        XCTAssertEqual(palette.commandSpanResults(for: "rerun safely").first?.command.id, .replay)
    }

    func testExecutableCommandSpanPaletteCommandsHideRowsWithoutRuntimeSupport() {
        XCTAssertTrue(TerminalCommandSpanPaletteActions.executableCommands(for: nil).isEmpty)

        let spanWithoutReplay = Self.span(id: 1, commandText: nil)
        XCTAssertEqual(
            TerminalCommandSpanPaletteActions.executableCommands(for: spanWithoutReplay).map(\.id),
            [.copyReference]
        )

        let replayableSpan = Self.span(id: 2, commandText: "swift test")
        XCTAssertEqual(
            TerminalCommandSpanPaletteActions.executableCommands(for: replayableSpan).map(\.id),
            [.copyReference, .replay]
        )
    }

    func testCommandSpanLocatorIncludesStableBoundaryCoordinates() {
        let span = Self.span(
            id: 42,
            startBoundarySequence: 10,
            outputBoundarySequence: 12,
            endBoundarySequence: 14,
            commandText: "swift test"
        )

        XCTAssertEqual(span.locatorString, "kurotty-command-span://42?start=10&output=12&end=14")
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

    private static func span(
        id: Int,
        startBoundarySequence: Int = 1,
        outputBoundarySequence: Int? = 2,
        endBoundarySequence: Int? = 3,
        commandText: String?
    ) -> TerminalCommandSpan {
        TerminalCommandSpan(
            id: id,
            cwd: "/repo",
            startBoundarySequence: startBoundarySequence,
            endBoundarySequence: endBoundarySequence,
            exitCode: 0,
            promptBoundarySequence: 0,
            outputBoundarySequence: outputBoundarySequence,
            commandText: commandText
        )
    }
}
