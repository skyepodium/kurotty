import AppKit
import XCTest
@testable import KurottyApp

/// Behavior coverage for search in the Preferences window.
///
/// The window is built imperatively into a stack, so these tests drive the real
/// `PreferencesView`: they type into the same controller the sidebar field
/// drives and then read which cards and rows survived. Matching itself is also
/// covered directly against `PreferencesSearchIndex`, which holds no views.
final class PreferencesSearchTests: XCTestCase {
    private enum Query {
        static let englishScrollback = "Scrollback"
        static let englishWindowHeight = "Height"
        static let englishHistoryCard = "History"
        static let englishPaletteColor = "Cursor"
        static let englishNoMatch = "zzzznotasetting"
        static let koreanWindowHeight = "높이"
        static let koreanScrollback = "스크롤백"
        static let japaneseScrollback = "スクロールバック"
        static let mixedCaseScrollback = "sCrOlLbAcK"
    }

    private enum EnglishLabel {
        static let shellCard = "Shell"
        static let historyCard = "History"
        static let textCard = "Text"
        static let editorCard = "Editor"
        static let quickCommandsCard = "Quick Commands"
        static let windowSizeCard = "Default window size"
        static let customColorsCard = "Custom colors"
        static let themeCard = "Terminal theme"
        static let scrollbackRow = "Scrollback"
        static let restoreScrollbackRow = "Restore scrollback"
        static let commandHistoryRow = "Command history"
        static let shellHistoryRow = "Shell history"
        static let workingDirectoryRow = "Working directory"
        static let widthRow = "Width"
        static let heightRow = "Height"
    }

    private enum KoreanLabel {
        static let historyCard = "기록"
        static let scrollbackRow = "스크롤백"
        static let restoreScrollbackRow = "스크롤백 복원"
        static let windowSizeCard = "기본 윈도우 크기"
        static let heightRow = "높이"
    }

    private enum JapaneseLabel {
        static let historyCard = "履歴"
        static let scrollbackRow = "スクロールバック"
        static let heightRow = "高さ"
    }

    private var temporaryDirectory: URL!
    private var originalLanguagePreference: AppLanguagePreference = .system

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-preferences-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        originalLanguagePreference = AppLocalization.preference
    }

    override func tearDownWithError() throws {
        AppLocalization.preference = originalLanguagePreference
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Cross-pane search

    /// The point of the feature: a setting is findable from whichever pane
    /// happens to be open, including one the user has never selected.
    @MainActor
    func testQueryMatchingAnotherPaneSwitchesToIt() throws {
        let view = try makeView(language: .english)
        XCTAssertEqual(view.selectedCategoryForTesting, .terminal)

        view.applySearchQueryForTesting(Query.englishWindowHeight)

        XCTAssertEqual(view.selectedCategoryForTesting, .window)
        XCTAssertEqual(view.visibleCardTitlesForTesting, [EnglishLabel.windowSizeCard])
        XCTAssertEqual(view.visibleRowLabelsForTesting, [EnglishLabel.heightRow])
        XCTAssertFalse(view.searchEmptyStateIsVisibleForTesting)
    }

    /// A pane that already has a match keeps the user where they are; typing
    /// must not shuffle them between panes on every keystroke.
    @MainActor
    func testQueryMatchingTheVisiblePaneStaysOnIt() throws {
        let view = try makeView(language: .english)

        view.applySearchQueryForTesting(Query.englishScrollback)

        XCTAssertEqual(view.selectedCategoryForTesting, .terminal)
    }

    // MARK: - Row and card visibility

    @MainActor
    func testNonMatchingRowsAndCardsAreHidden() throws {
        let view = try makeView(language: .english)

        view.applySearchQueryForTesting(Query.englishScrollback)

        XCTAssertEqual(view.visibleCardTitlesForTesting, [EnglishLabel.historyCard])
        XCTAssertEqual(
            view.visibleRowLabelsForTesting,
            [EnglishLabel.scrollbackRow, EnglishLabel.restoreScrollbackRow]
        )
        XCTAssertFalse(view.visibleRowLabelsForTesting.contains(EnglishLabel.commandHistoryRow))
        XCTAssertFalse(view.visibleCardTitlesForTesting.contains(EnglishLabel.shellCard))
        XCTAssertFalse(view.visibleCardTitlesForTesting.contains(EnglishLabel.quickCommandsCard))
    }

    @MainActor
    func testMatchingIsCaseInsensitive() throws {
        let view = try makeView(language: .english)

        view.applySearchQueryForTesting(Query.mixedCaseScrollback)

        XCTAssertEqual(view.visibleCardTitlesForTesting, [EnglishLabel.historyCard])
        XCTAssertTrue(view.visibleRowLabelsForTesting.contains(EnglishLabel.scrollbackRow))
    }

    /// A card title is searchable too, and a title hit keeps the card whole:
    /// hiding rows inside a card the user searched for by name would be a lie.
    @MainActor
    func testCardTitleMatchKeepsEveryRowInThatCard() throws {
        let view = try makeView(language: .english)

        view.applySearchQueryForTesting(Query.englishHistoryCard)

        XCTAssertEqual(
            view.visibleCardTitlesForTesting,
            [EnglishLabel.shellCard, EnglishLabel.historyCard]
        )
        // The Shell card survives only through the one row that matches.
        XCTAssertFalse(view.visibleRowLabelsForTesting.contains(EnglishLabel.workingDirectoryRow))
        XCTAssertTrue(view.visibleRowLabelsForTesting.contains(EnglishLabel.shellHistoryRow))
        // The History card matched by title, so a row that does not match the
        // query is still visible.
        XCTAssertTrue(view.visibleRowLabelsForTesting.contains(EnglishLabel.scrollbackRow))
        XCTAssertTrue(view.visibleRowLabelsForTesting.contains(EnglishLabel.commandHistoryRow))
    }

    @MainActor
    func testClearingTheQueryRestoresEveryCardAndRow() throws {
        let view = try makeView(language: .english)
        let allCards = view.visibleCardTitlesForTesting
        let allRows = view.visibleRowLabelsForTesting

        view.applySearchQueryForTesting(Query.englishScrollback)
        view.applySearchQueryForTesting("")

        XCTAssertEqual(view.visibleCardTitlesForTesting, allCards)
        XCTAssertEqual(view.visibleRowLabelsForTesting, allRows)
        XCTAssertTrue(allCards.contains(EnglishLabel.shellCard))
        XCTAssertTrue(allCards.contains(EnglishLabel.textCard))
        XCTAssertTrue(allCards.contains(EnglishLabel.editorCard))
        XCTAssertTrue(allCards.contains(EnglishLabel.quickCommandsCard))
        XCTAssertTrue(allRows.contains(EnglishLabel.workingDirectoryRow))
        XCTAssertFalse(view.searchEmptyStateIsVisibleForTesting)
    }

    /// Whitespace is not a query. A stray space must not empty the window.
    @MainActor
    func testWhitespaceQueryDoesNotFilter() throws {
        let view = try makeView(language: .english)
        let allCards = view.visibleCardTitlesForTesting

        view.applySearchQueryForTesting("   ")

        XCTAssertEqual(view.visibleCardTitlesForTesting, allCards)
        XCTAssertFalse(view.searchEmptyStateIsVisibleForTesting)
    }

    // MARK: - Empty state

    @MainActor
    func testQueryWithNoMatchAnywhereShowsTheEmptyStateAndKeepsThePane() throws {
        let view = try makeView(language: .english)

        view.applySearchQueryForTesting(Query.englishNoMatch)

        XCTAssertEqual(view.selectedCategoryForTesting, .terminal)
        XCTAssertTrue(view.visibleCardTitlesForTesting.isEmpty)
        XCTAssertTrue(view.searchEmptyStateIsVisibleForTesting)
        XCTAssertTrue(view.searchEmptyStateMessageForTesting.contains(Query.englishNoMatch))
    }

    // MARK: - Settings-gated cards

    /// The custom palette exists only under the custom theme. Search must not
    /// advertise a card the user cannot see.
    @MainActor
    func testPaletteColorIsFoundOnlyWhileTheCustomThemeIsSelected() throws {
        let defaultThemeView = try makeView(language: .english)
        defaultThemeView.applySearchQueryForTesting(Query.englishPaletteColor)

        XCTAssertEqual(defaultThemeView.selectedCategoryForTesting, .terminal)
        XCTAssertTrue(defaultThemeView.searchEmptyStateIsVisibleForTesting)

        let customThemeView = try makeView(language: .english, theme: TerminalThemePreset.customName)
        customThemeView.applySearchQueryForTesting(Query.englishPaletteColor)

        XCTAssertEqual(customThemeView.selectedCategoryForTesting, .appearance)
        XCTAssertEqual(customThemeView.visibleCardTitlesForTesting, [EnglishLabel.customColorsCard])
        XCTAssertFalse(customThemeView.searchEmptyStateIsVisibleForTesting)
    }

    // MARK: - Localization

    @MainActor
    func testSearchMatchesKoreanCopy() throws {
        let view = try makeView(language: .korean)

        view.applySearchQueryForTesting(Query.koreanScrollback)

        XCTAssertEqual(view.selectedCategoryForTesting, .terminal)
        XCTAssertEqual(view.visibleCardTitlesForTesting, [KoreanLabel.historyCard])
        XCTAssertEqual(
            view.visibleRowLabelsForTesting,
            [KoreanLabel.scrollbackRow, KoreanLabel.restoreScrollbackRow]
        )

        view.applySearchQueryForTesting(Query.koreanWindowHeight)

        XCTAssertEqual(view.selectedCategoryForTesting, .window)
        XCTAssertEqual(view.visibleCardTitlesForTesting, [KoreanLabel.windowSizeCard])
        XCTAssertEqual(view.visibleRowLabelsForTesting, [KoreanLabel.heightRow])
    }

    @MainActor
    func testSearchMatchesJapaneseCopy() throws {
        let view = try makeView(language: .japanese)

        view.applySearchQueryForTesting(Query.japaneseScrollback)

        XCTAssertEqual(view.selectedCategoryForTesting, .terminal)
        XCTAssertEqual(view.visibleCardTitlesForTesting, [JapaneseLabel.historyCard])
        XCTAssertTrue(view.visibleRowLabelsForTesting.contains(JapaneseLabel.scrollbackRow))

        view.applySearchQueryForTesting(JapaneseLabel.heightRow)

        XCTAssertEqual(view.selectedCategoryForTesting, .window)
        XCTAssertEqual(view.visibleRowLabelsForTesting, [JapaneseLabel.heightRow])
    }

    /// English copy stays findable in every language build, because the theme
    /// preset names and units are not translated.
    @MainActor
    func testEveryPaneIsIndexedBeforeItIsFirstOpened() throws {
        for language in [AppLanguagePreference.english, .korean, .japanese] {
            let view = try makeView(language: language)
            for category in PreferencesCategory.allCases {
                XCTAssertFalse(
                    view.searchIndexForTesting.cards(for: category).isEmpty,
                    "\(category) was not indexed for \(language)"
                )
            }
        }
    }

    // MARK: - Keyboard

    /// Cmd+F is dispatched down the key window's responder chain, so the
    /// Settings window has to answer the Find action itself. Anything less and
    /// the shortcut reaches the app delegate's terminal search instead.
    @MainActor
    func testFindActionFocusesTheSearchField() throws {
        let view = try makeView(language: .english)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        XCTAssertFalse(view.searchFieldIsFocusedForTesting)
        XCTAssertTrue(view.responds(to: #selector(AppDelegate.findTerminalOutput)))

        view.findTerminalOutput()

        XCTAssertTrue(view.searchFieldIsFocusedForTesting)
    }

    // MARK: - Index rules

    func testIndexPrefersTheVisiblePaneWhenBothMatch() {
        var index = PreferencesSearchIndex()
        index.setCards([PreferencesSearchIndex.Card(title: "Text", rowLabels: ["Font size"])], for: .terminal)
        index.setCards([PreferencesSearchIndex.Card(title: "Size", rowLabels: ["Width"])], for: .window)

        XCTAssertEqual(index.resolvedCategory(for: "size", current: .window), .window)
        XCTAssertEqual(index.resolvedCategory(for: "size", current: .terminal), .terminal)
        XCTAssertEqual(index.resolvedCategory(for: "width", current: .terminal), .window)
        XCTAssertEqual(index.resolvedCategory(for: "nothing", current: .terminal), .terminal)
        XCTAssertEqual(index.resolvedCategory(for: "  ", current: .appearance), .appearance)
    }

    func testCardVisibilityRules() {
        let card = PreferencesSearchIndex.Card(
            title: "History",
            rowLabels: ["Scrollback", "Command history"],
            keywords: ["Edit Quick Commands…"]
        )

        XCTAssertEqual(card.visibility(for: nil), .whole)
        XCTAssertEqual(card.visibility(for: "history"), .whole)
        XCTAssertEqual(card.visibility(for: "quick"), .whole)
        XCTAssertEqual(card.visibility(for: "scroll"), .matchingRows([0]))
        XCTAssertEqual(card.visibility(for: "font"), .hidden)
    }

    // MARK: - Helpers

    @MainActor
    private func makeView(
        language: AppLanguagePreference,
        theme: String = TerminalThemePreset.kurottyName
    ) throws -> PreferencesView {
        AppLocalization.preference = language
        let store = AppSettingsStore(
            settingsURL: temporaryDirectory
                .appendingPathComponent("settings-\(UUID().uuidString).json")
        )
        var settings = AppSettings.default
        settings.terminal.theme = theme
        try store.save(settings)
        return PreferencesView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Component.preferencesWidthPX,
                height: DesignTokens.Component.preferencesHeightPX
            ),
            store: store
        )
    }
}
