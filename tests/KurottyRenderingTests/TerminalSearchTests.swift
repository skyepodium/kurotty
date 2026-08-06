import AppKit
import KurottyCore
import XCTest
@testable import KurottyApp

final class TerminalSearchTests: XCTestCase {
    private final class StubSession: TerminalSession {
        var onOutput: ((String) -> Void)?
        var onRawOutput: ((Data) -> Void)?
        var onRuntimeEvent: ((TerminalEventLedger.RecordedEvent) -> Void)?
        var onExit: ((Int32) -> Void)?
        var writes: [String] = []

        func start(workingDirectory: String) {}
        func write(_ text: String) { writes.append(text) }
        func foregroundProcessName() -> String? { "zsh" }
        func canReceiveTerminalResponseWithoutEcho() -> Bool { true }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    func testMatcherFindsCaseInsensitiveMatchesInDocumentOrder() {
        let rows = [row("Kurotty kuroTTY other"), row("no match"), row("KUROTTY")]

        let matches = TerminalSearchMatcher.findAll(query: "kurotty", in: rows)

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 0, endColumn: 7),
            TerminalSearchMatch(row: 0, startColumn: 8, endColumn: 15),
            TerminalSearchMatch(row: 2, startColumn: 0, endColumn: 7),
        ])
    }

    func testMatcherMapsWideCharactersBackToTerminalColumns() {
        let matches = TerminalSearchMatcher.findAll(query: "한글", in: [row("a한글z")])

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 1, endColumn: 5),
        ])
    }

    func testMatcherTreatsQueryAsLiteralText() {
        let matches = TerminalSearchMatcher.findAll(query: "[a]", in: [row("[a] a")])

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 0, endColumn: 3),
        ])
    }

    func testMatcherSearchesMeaningfulSpacesWithoutMatchingTrailingPaddingOrBlankRows() {
        let matches = TerminalSearchMatcher.findAll(
            query: " ",
            in: [row("a b", columns: 8), row("", columns: 8), row("  c", columns: 8)]
        )

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 1, endColumn: 2),
            TerminalSearchMatch(row: 2, startColumn: 0, endColumn: 1),
            TerminalSearchMatch(row: 2, startColumn: 1, endColumn: 2),
        ])
    }

    func testMatcherMapsRecombinedRegionalIndicatorCellsUsingUTF16Offsets() {
        let firstIndicator: Character = "🇰"
        let secondIndicator: Character = "🇷"
        let firstWidth = max(1, firstIndicator.terminalColumnWidth)
        let secondWidth = max(1, secondIndicator.terminalColumnWidth)
        var cells = Array(repeating: TerminalScreenCell(), count: firstWidth + secondWidth + 4)
        cells[0].character = firstIndicator
        if firstWidth > 1 {
            for column in 1..<firstWidth {
                cells[column].isContinuation = true
            }
        }
        cells[firstWidth].character = secondIndicator
        if secondWidth > 1 {
            for column in (firstWidth + 1)..<(firstWidth + secondWidth) {
                cells[column].isContinuation = true
            }
        }

        XCTAssertEqual(TerminalSearchMatcher.findAll(query: "🇰🇷", in: [cells]), [
            TerminalSearchMatch(row: 0, startColumn: 0, endColumn: firstWidth + secondWidth),
        ])
    }

    func testMatcherFindsMatchSplitAcrossOneSoftWrap() {
        let matches = TerminalSearchMatcher.findAll(
            query: "needle",
            in: [wrappedRow("abcdneed", columns: 8), row("le xyz", columns: 8)]
        )

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 4, endRow: 1, endColumn: 2),
        ])
    }

    func testMatcherFindsMatchSpanningThreeSoftWrappedRows() {
        let matches = TerminalSearchMatcher.findAll(
            query: "needle",
            in: [wrappedRow("xxn", columns: 3), wrappedRow("eed", columns: 3), row("le", columns: 3)]
        )

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 2, endRow: 2, endColumn: 2),
        ])
    }

    func testMatcherKeepsMatchEndingOnTheWrapBoundaryOnOneRow() {
        let matches = TerminalSearchMatcher.findAll(
            query: "needle",
            in: [wrappedRow("abneedle", columns: 8), row("xyz", columns: 8)]
        )

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 2, endColumn: 8),
        ])
    }

    func testMatcherKeepsMatchStartingOnTheWrapBoundaryOnOneRow() {
        let matches = TerminalSearchMatcher.findAll(
            query: "needle",
            in: [wrappedRow("abcdefgh", columns: 8), row("needle!", columns: 8)]
        )

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 1, startColumn: 0, endColumn: 6),
        ])
    }

    /// The joining is soft-wrap only. Two rows the shell printed as two lines
    /// are two lines, and running them together would invent matches.
    func testMatcherDoesNotJoinRowsSeparatedByHardNewline() {
        let hardBreak = [row("abcdneed", columns: 8), row("le xyz", columns: 8)]

        XCTAssertEqual(TerminalSearchMatcher.findAll(query: "needle", in: hardBreak), [])
    }

    func testWrappedMatchHighlightsEveryRowItCovers() {
        let results = TerminalSearchResults(matches: TerminalSearchMatcher.findAll(
            query: "needle",
            in: [wrappedRow("xxn", columns: 3), wrappedRow("eed", columns: 3), row("le", columns: 3)]
        ))
        func highlight(_ row: Int, _ column: Int) -> TerminalSearchHighlightKind? {
            results.highlight(
                at: TerminalCellPosition(row: row, column: column),
                currentMatch: nil
            )
        }

        XCTAssertNil(highlight(0, 1))
        XCTAssertEqual(highlight(0, 2), .match)
        XCTAssertEqual(highlight(1, 0), .match)
        XCTAssertEqual(highlight(1, 2), .match)
        XCTAssertEqual(highlight(2, 0), .match)
        XCTAssertEqual(highlight(2, 1), .match)
        XCTAssertNil(highlight(2, 2))
    }

    func testWrappedLineMatchesStillHonourTheMatchCap() {
        let scanResult = TerminalSearchMatcher.scan(
            query: "ab",
            in: TerminalSearchSnapshot(
                scrollbackRows: BoundedScrollbackRows(),
                screenRows: [wrappedRow("abab", columns: 4), row("ab", columns: 4)]
            ),
            maximumMatchCount: 2
        )

        XCTAssertEqual(scanResult.matches, [
            TerminalSearchMatch(row: 0, startColumn: 0, endColumn: 2),
            TerminalSearchMatch(row: 0, startColumn: 2, endColumn: 4),
        ])
        XCTAssertTrue(scanResult.isTruncated)
    }

    /// A line with no newline in it can be as long as the scrollback, so the
    /// join is bounded. Everything up to the bound still matches as one line.
    func testWrappedLineJoinStopsAtItsRowBound() {
        let rows = [
            wrappedRow("ab", columns: 2),
            wrappedRow("cd", columns: 2),
            wrappedRow("ef", columns: 2),
            row("gh", columns: 2),
        ]

        XCTAssertEqual(
            TerminalSearchMatcher.scan(
                query: "cdef",
                in: TerminalSearchSnapshot(
                    scrollbackRows: BoundedScrollbackRows(),
                    screenRows: rows
                ),
                maximumWrappedRowJoinCount: 2
            ).matches,
            []
        )
        XCTAssertEqual(
            TerminalSearchMatcher.scan(
                query: "cdef",
                in: TerminalSearchSnapshot(
                    scrollbackRows: BoundedScrollbackRows(),
                    screenRows: rows
                ),
                maximumWrappedRowJoinCount: 4
            ).matches,
            [TerminalSearchMatch(row: 1, startColumn: 0, endRow: 2, endColumn: 2)]
        )
    }

    func testCaseSensitiveOptionNarrowsResultsOnTheSameRows() {
        let rows = [row("Needle needle")]

        XCTAssertEqual(TerminalSearchMatcher.findAll(query: "needle", in: rows).count, 2)
        XCTAssertEqual(
            TerminalSearchMatcher.findAll(
                query: "needle",
                options: TerminalSearchOptions(isCaseSensitive: true),
                in: rows
            ),
            [TerminalSearchMatch(row: 0, startColumn: 7, endColumn: 13)]
        )
    }

    func testRegularExpressionOptionChangesHowMetacharactersAreRead() {
        let rows = [row("a.c abc")]

        XCTAssertEqual(
            TerminalSearchMatcher.findAll(query: "a.c", in: rows),
            [TerminalSearchMatch(row: 0, startColumn: 0, endColumn: 3)]
        )
        XCTAssertEqual(
            TerminalSearchMatcher.findAll(
                query: "a.c",
                options: TerminalSearchOptions(usesRegularExpression: true),
                in: rows
            ),
            [
                TerminalSearchMatch(row: 0, startColumn: 0, endColumn: 3),
                TerminalSearchMatch(row: 0, startColumn: 4, endColumn: 7),
            ]
        )
    }

    func testRegularExpressionMatchesAcrossASoftWrapToo() {
        let matches = TerminalSearchMatcher.findAll(
            query: "ne+dle",
            options: TerminalSearchOptions(usesRegularExpression: true),
            in: [wrappedRow("abcdneee", columns: 8), row("dle xyz", columns: 8)]
        )

        XCTAssertEqual(matches, [
            TerminalSearchMatch(row: 0, startColumn: 4, endRow: 1, endColumn: 3),
        ])
    }

    /// Half a pattern is what every regex looks like while it is being typed.
    func testUnparsableRegularExpressionMatchesNothingInsteadOfFailing() {
        let scanResult = TerminalSearchMatcher.scan(
            query: "(unclosed",
            options: TerminalSearchOptions(usesRegularExpression: true),
            in: TerminalSearchSnapshot(
                scrollbackRows: BoundedScrollbackRows(),
                screenRows: [row("(unclosed group")]
            )
        )

        XCTAssertEqual(scanResult.matches, [])
        XCTAssertFalse(scanResult.isTruncated)
        XCTAssertFalse(TerminalSearchPattern.isValidQuery(
            "(unclosed",
            options: TerminalSearchOptions(usesRegularExpression: true)
        ))
        XCTAssertTrue(TerminalSearchPattern.isValidQuery(
            "(unclosed",
            options: .default
        ))
    }

    /// A pattern that can match nothing must not stall the scan on it.
    func testZeroWidthRegularExpressionMatchesAreSteppedOver() {
        let matches = TerminalSearchMatcher.findAll(
            query: "x*",
            options: TerminalSearchOptions(usesRegularExpression: true),
            in: [row("abxc")]
        )

        XCTAssertEqual(matches, [TerminalSearchMatch(row: 0, startColumn: 2, endColumn: 3)])
    }

    func testMatcherCapsCommonResultsAroundCurrentViewportAndReportsTruncation() {
        let rows = (0..<6).map { _ in row("x", columns: 4) }
        let scanResult = TerminalSearchMatcher.scan(
            query: "x",
            in: TerminalSearchSnapshot(
                scrollbackRows: BoundedScrollbackRows(),
                screenRows: rows,
                preferredStartRow: 4
            ),
            maximumMatchCount: 3
        )

        XCTAssertEqual(scanResult.matches, [
            TerminalSearchMatch(row: 0, startColumn: 0, endColumn: 1),
            TerminalSearchMatch(row: 4, startColumn: 0, endColumn: 1),
            TerminalSearchMatch(row: 5, startColumn: 0, endColumn: 1),
        ])
        XCTAssertTrue(scanResult.isTruncated)
        XCTAssertEqual(
            TerminalSearchSummary(currentIndex: 0, totalMatches: 3, isTruncated: true).displayText,
            "1/3+"
        )
    }

    func testMatcherDoesNotReportTruncationWhenResultCountExactlyMatchesLimit() {
        let scanResult = TerminalSearchMatcher.scan(
            query: "x",
            in: TerminalSearchSnapshot(
                scrollbackRows: BoundedScrollbackRows(),
                screenRows: [row("x"), row("x"), row("x")]
            ),
            maximumMatchCount: 3
        )

        XCTAssertEqual(scanResult.matches.count, 3)
        XCTAssertFalse(scanResult.isTruncated)
    }

    func testResultSetDistinguishesCurrentMatchFromOtherHighlights() {
        let first = TerminalSearchMatch(row: 3, startColumn: 1, endColumn: 4)
        let current = TerminalSearchMatch(row: 3, startColumn: 7, endColumn: 10)
        let results = TerminalSearchResults(matches: [first, current])

        XCTAssertEqual(
            results.highlight(at: TerminalCellPosition(row: 3, column: 2), currentMatch: current),
            .match
        )
        XCTAssertEqual(
            results.highlight(at: TerminalCellPosition(row: 3, column: 8), currentMatch: current),
            .current
        )
        XCTAssertNil(results.highlight(at: TerminalCellPosition(row: 3, column: 5), currentMatch: current))
    }

    func testNavigationStartsAtLastMatchBeforeViewportEndAndWraps() {
        let matches = [
            TerminalSearchMatch(row: 1, startColumn: 0, endColumn: 1),
            TerminalSearchMatch(row: 5, startColumn: 0, endColumn: 1),
            TerminalSearchMatch(row: 9, startColumn: 0, endColumn: 1),
        ]

        XCTAssertEqual(
            TerminalSearchNavigation.preferredInitialIndex(matches: matches, visibleRows: 4..<8),
            1
        )
        XCTAssertEqual(TerminalSearchNavigation.movedIndex(from: 1, by: 1, matchCount: 3), 2)
        XCTAssertEqual(TerminalSearchNavigation.movedIndex(from: 2, by: 1, matchCount: 3), 0)
        XCTAssertEqual(TerminalSearchNavigation.movedIndex(from: 0, by: -1, matchCount: 3), 2)
    }

    func testScrollbackOffsetRevealsMatchesAboveAndBelowViewport() {
        XCTAssertEqual(
            TerminalSearchNavigation.scrollbackOffsetToReveal(
                row: 5,
                contentRowCount: 100,
                visibleRowCount: 10,
                currentOffset: 0
            ),
            85
        )
        XCTAssertEqual(
            TerminalSearchNavigation.scrollbackOffsetToReveal(
                row: 50,
                contentRowCount: 100,
                visibleRowCount: 10,
                currentOffset: 85
            ),
            49
        )
        XCTAssertEqual(
            TerminalSearchNavigation.scrollbackOffsetToReveal(
                row: 97,
                contentRowCount: 100,
                visibleRowCount: 10,
                currentOffset: 0
            ),
            0
        )
    }

    @MainActor
    func testSurfaceSearchUpdatesLiveAndScrollsWhenMovingBetweenMatches() async {
        let surface = TerminalSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 120),
            session: StubSession()
        )
        let output = (0..<24).map { rowIndex in
            [2, 10, 22].contains(rowIndex) ? "row \(rowIndex) needle" : "row \(rowIndex)"
        }.joined(separator: "\r\n")
        surface.consumeTmuxRestoreOutputForTesting(Data(output.utf8))

        let resultsUpdated = expectation(description: "search results updated")
        var didObserveResults = false
        surface.onSearchSummaryChange = { summary in
            if summary.totalMatches == 3, !didObserveResults {
                didObserveResults = true
                resultsUpdated.fulfill()
            }
        }
        surface.beginSearchPresentation()
        surface.updateSearchQuery("needle")
        await fulfillment(of: [resultsUpdated], timeout: 2)
        surface.onSearchSummaryChange = nil

        let initial = surface.searchStateForTesting
        XCTAssertEqual(initial.summary, TerminalSearchSummary(currentIndex: 2, totalMatches: 3))
        XCTAssertEqual(initial.currentMatch?.row, 22)
        XCTAssertTrue(initial.visibleRows.contains(22))

        surface.selectPreviousSearchMatch()

        let previous = surface.searchStateForTesting
        XCTAssertEqual(previous.summary.currentIndex, 1)
        XCTAssertEqual(previous.currentMatch?.row, 10)
        XCTAssertTrue(previous.visibleRows.contains(10))
        XCTAssertGreaterThan(previous.scrollbackOffset, 0)

        surface.selectNextSearchMatch()

        let next = surface.searchStateForTesting
        XCTAssertEqual(next.currentMatch?.row, 22)
        XCTAssertTrue(next.visibleRows.contains(22))

        let liveResultsUpdated = expectation(description: "live search results updated")
        surface.onSearchSummaryChange = { summary in
            if summary.totalMatches == 4 {
                liveResultsUpdated.fulfill()
            }
        }
        surface.consumeTmuxRestoreOutputForTesting(Data(" live needle".utf8))
        XCTAssertEqual(surface.searchStateForTesting.summary, .empty)
        await fulfillment(of: [liveResultsUpdated], timeout: 2)
        XCTAssertEqual(surface.searchStateForTesting.summary.totalMatches, 4)
    }

    @MainActor
    func testSwitchingTabsClosesSearchInDepartingTab() throws {
        let firstPane = TerminalPaneView(frame: .zero, session: StubSession())
        let secondPane = TerminalPaneView(frame: .zero, session: StubSession())
        let controller = TerminalWindowController(
            detachedPane: firstPane,
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
        controller.attachDraggedPaneAsTab(secondPane)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder.first === secondPane)

        controller.findTerminalOutput()
        XCTAssertTrue(secondPane.isSearchVisibleForTesting)

        controller.selectPreviousTab()

        XCTAssertFalse(secondPane.isSearchVisibleForTesting)
        XCTAssertTrue(controller.selectedTerminalPanesInLayoutOrder.first === firstPane)
    }

    @MainActor
    func testEscapeClosesActiveSurfaceSearchWithoutWritingToPty() throws {
        let session = StubSession()
        let surface = TerminalSurfaceView(frame: .init(x: 0, y: 0, width: 500, height: 120), session: session)
        var closeCount = 0
        surface.closeSearchRequested = { closeCount += 1 }
        surface.beginSearchPresentation()
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))

        surface.keyDown(with: escape)

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(session.writes.isEmpty)
    }

    @MainActor
    func testSearchBarRoutesReturnShiftReturnAndEscape() {
        let searchBar = TerminalSearchBarView()
        var nextCount = 0
        var previousCount = 0
        var closeCount = 0
        searchBar.onNextMatch = { nextCount += 1 }
        searchBar.onPreviousMatch = { previousCount += 1 }
        searchBar.onClose = { closeCount += 1 }

        searchBar.submit(modifiers: [])
        searchBar.submit(modifiers: [.shift, .capsLock])
        let handledEscape = searchBar.control(
            NSTextField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(previousCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(handledEscape)
    }

    @MainActor
    func testSearchBarQueryFieldRemainsEditableAfterInstallingCenteredCell() throws {
        let searchBar = TerminalSearchBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 44))
        let queryField = try XCTUnwrap(searchBarQueryField(in: searchBar))

        XCTAssertTrue(queryField.isEditable)
        XCTAssertTrue(queryField.isSelectable)
        XCTAssertTrue(queryField.usesSingleLineMode)
        XCTAssertFalse(queryField.drawsBackground)
        XCTAssertNotNil(queryField.layer?.backgroundColor)
    }

    @MainActor
    func testSearchBarExpandsLargeResultCountWithoutClipping() throws {
        let searchBar = TerminalSearchBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 44))
        searchBar.update(summary: TerminalSearchSummary(
            currentIndex: 49_999,
            totalMatches: 50_000,
            isTruncated: true
        ))
        searchBar.layoutSubtreeIfNeeded()
        let resultLabel = try XCTUnwrap(searchBarResultLabel(in: searchBar))

        XCTAssertEqual(resultLabel.stringValue, "50000/50000+")
        XCTAssertGreaterThanOrEqual(
            resultLabel.frame.width.rounded(.up),
            resultLabel.intrinsicContentSize.width.rounded(.up)
        )
    }

    @MainActor
    func testSearchBarKeepsQueryAndCloseVisibleAtNarrowPaneWidth() throws {
        let searchBar = TerminalSearchBarView()
        searchBar.frame = NSRect(x: 0, y: 0, width: 150, height: 44)
        searchBar.layout()
        let stack = try XCTUnwrap(searchBar.subviews.compactMap { $0 as? NSStackView }.first)
        let queryField = try XCTUnwrap(searchBarQueryField(in: searchBar))
        let resultLabel = try XCTUnwrap(searchBarResultLabel(in: searchBar))
        let previousButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .previousSearchMatch))
        let nextButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .nextSearchMatch))
        let matchCaseButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .matchCase))
        let regexButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .useRegularExpression))
        let closeButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .closeSearch))

        XCTAssertTrue(resultLabel.isHidden)
        XCTAssertTrue(previousButton.isHidden)
        XCTAssertTrue(nextButton.isHidden)
        XCTAssertTrue(matchCaseButton.isHidden)
        XCTAssertTrue(regexButton.isHidden)
        XCTAssertFalse(queryField.isHidden)
        XCTAssertFalse(closeButton.isHidden)
        XCTAssertLessThanOrEqual(stack.frame.maxX, searchBar.bounds.maxX - 6)
    }

    @MainActor
    func testSearchBarOptionTogglesReportBothOptionsAndKeepTheirState() throws {
        let searchBar = TerminalSearchBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        searchBar.layout()
        var reported: [TerminalSearchOptions] = []
        searchBar.onOptionsChanged = { reported.append($0) }
        let matchCaseButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .matchCase))
        let regexButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .useRegularExpression))

        XCTAssertEqual(searchBar.searchOptions, .default)
        matchCaseButton.performClick(nil)
        regexButton.performClick(nil)

        XCTAssertEqual(reported, [
            TerminalSearchOptions(isCaseSensitive: true),
            TerminalSearchOptions(isCaseSensitive: true, usesRegularExpression: true),
        ])
        XCTAssertEqual(matchCaseButton.accessibilityValue() as? Bool, true)

        matchCaseButton.performClick(nil)

        XCTAssertEqual(
            searchBar.searchOptions,
            TerminalSearchOptions(isCaseSensitive: false, usesRegularExpression: true)
        )
        XCTAssertEqual(matchCaseButton.accessibilityValue() as? Bool, false)
    }

    @MainActor
    func testSearchBarShowsAnUnfinishedRegexAsInvalidAndRecoversWhenItParses() throws {
        let theme = DesignTokens.ChromeTheme.dark
        let searchBar = TerminalSearchBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        searchBar.applyChromeTheme(theme)
        searchBar.layout()
        let queryField = try XCTUnwrap(searchBarQueryField(in: searchBar))
        let regexButton = try XCTUnwrap(searchBarButton(in: searchBar, labelled: .useRegularExpression))
        regexButton.performClick(nil)

        queryField.stringValue = "(unclosed"
        searchBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        XCTAssertEqual(searchBar.layer?.borderColor, theme.error.cgColor)
        XCTAssertEqual(regexButton.contentTintColor, theme.error)

        queryField.stringValue = "(closed)"
        searchBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        XCTAssertEqual(searchBar.layer?.borderColor, theme.hairline.cgColor)
        XCTAssertEqual(regexButton.contentTintColor, theme.accent)
    }

    @MainActor
    func testSearchBarLeavesAnUnfinishedRegexAloneWhileRegexIsOff() throws {
        let theme = DesignTokens.ChromeTheme.dark
        let searchBar = TerminalSearchBarView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        searchBar.applyChromeTheme(theme)
        let queryField = try XCTUnwrap(searchBarQueryField(in: searchBar))

        queryField.stringValue = "(unclosed"
        searchBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        XCTAssertEqual(searchBar.layer?.borderColor, theme.hairline.cgColor)
    }

    private func row(_ text: String, columns: Int = 40) -> [TerminalScreenCell] {
        var cells = Array(repeating: TerminalScreenCell(), count: columns)
        var column = 0
        for character in text where column < columns {
            let width = max(1, character.terminalColumnWidth)
            guard column + width <= columns else { break }
            cells[column].character = character
            if width > 1 {
                for continuationColumn in (column + 1)..<(column + width) {
                    cells[continuationColumn].isContinuation = true
                }
            }
            column += width
        }
        return cells
    }

    /// A row the terminal filled to the edge and continued on the next one. The
    /// marker lives on the last cell, exactly as `TerminalScreen` writes it.
    private func wrappedRow(_ text: String, columns: Int) -> [TerminalScreenCell] {
        var cells = row(text, columns: columns)
        cells[columns - 1].wrapsToNextRow = true
        return cells
    }

    @MainActor
    private func searchBarQueryField(in searchBar: TerminalSearchBarView) -> NSTextField? {
        searchBar.subviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.isEditable })
    }

    @MainActor
    private func searchBarButton(
        in searchBar: TerminalSearchBarView,
        labelled key: L10nKey
    ) -> NSButton? {
        let label = AppLocalization.string(key)
        return searchBar.subviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSButton }
            .first(where: { $0.accessibilityLabel() == label })
    }

    @MainActor
    private func searchBarResultLabel(in searchBar: TerminalSearchBarView) -> NSTextField? {
        searchBar.subviews
            .compactMap { $0 as? NSStackView }
            .flatMap { $0.arrangedSubviews }
            .compactMap { $0 as? NSTextField }
            .first(where: { !$0.isEditable })
    }
}
