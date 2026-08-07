import XCTest
@testable import KurottyApp

/// Selection, keyboard navigation, activation, and footer state for the project
/// file palette. No window is built: everything asserted here is a value the
/// presenter computes.
final class ProjectFileQuickOpenPresenterTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/projects/demo", isDirectory: true)

    private func listing(
        _ paths: [String],
        source: ProjectFileListingSource = .ripgrep,
        isTruncated: Bool = false
    ) -> ProjectFileListing {
        ProjectFileListing(relativePaths: paths, source: source, isTruncated: isTruncated)
    }

    private func presenter(
        _ paths: [String],
        query: String = "",
        visibleLimit: Int = 50
    ) -> ProjectFileQuickOpenPresenter {
        ProjectFileQuickOpenPresenter(
            rootDirectory: root,
            listing: listing(paths),
            query: query,
            visibleLimit: visibleLimit
        )
    }

    // MARK: - Scan lifecycle

    func testAPresenterWithNoListingYetIsScanning() {
        let presenter = ProjectFileQuickOpenPresenter(rootDirectory: root)
        XCTAssertTrue(presenter.isScanning)
        XCTAssertEqual(presenter.status, .scanning)
        XCTAssertNil(presenter.selectedIndex)
    }

    func testAQueryTypedBeforeTheScanLandsIsKeptAndApplied() {
        // The scan is asynchronous and a fast typist beats it. Resetting the
        // query on arrival would eat their keystrokes.
        var presenter = ProjectFileQuickOpenPresenter(rootDirectory: root)
        presenter.updateQuery("main")
        presenter.applyListing(listing(["src/main.swift", "src/other.swift"]))

        XCTAssertEqual(presenter.query, "main")
        XCTAssertEqual(presenter.visibleMatches.map(\.relativePath), ["src/main.swift"])
    }

    func testAnEmptyProjectIsDistinctFromNoMatches() {
        // One means the query is wrong; the other means the directory is empty
        // or unreadable. They call for different words on screen.
        var empty = ProjectFileQuickOpenPresenter(rootDirectory: root)
        empty.applyListing(listing([]))
        XCTAssertEqual(empty.status, .emptyProject)

        var populated = presenter(["a.swift"])
        populated.updateQuery("zzz")
        XCTAssertEqual(populated.status, .noMatches)
    }

    // MARK: - Keyboard navigation

    func testSelectionStartsOnTheFirstRowOnceResultsExist() {
        XCTAssertEqual(presenter(["a.swift", "b.swift"]).selectedIndex, 0)
    }

    func testArrowingDownAndUpMovesOneRowAtATime() {
        var presenter = presenter(["a.swift", "b.swift", "c.swift"])
        presenter.moveSelection(by: 1)
        XCTAssertEqual(presenter.selectedIndex, 1)
        presenter.moveSelection(by: -1)
        XCTAssertEqual(presenter.selectedIndex, 0)
    }

    func testSelectionClampsAtBothEndsRatherThanWrapping() {
        // Matches `CommandPalettePresenter`. Two palettes in one app that
        // disagree about what Down does at the last row is worse than either
        // behavior chosen on its own.
        var presenter = presenter(["a.swift", "b.swift"])
        presenter.moveSelection(by: 10)
        XCTAssertEqual(presenter.selectedIndex, 1)
        presenter.moveSelection(by: -10)
        XCTAssertEqual(presenter.selectedIndex, 0)
    }

    func testArrowingWithNoResultsLeavesNothingSelected() {
        var presenter = presenter(["a.swift"])
        presenter.updateQuery("zzz")
        presenter.moveSelection(by: 1)
        XCTAssertNil(presenter.selectedIndex)
        XCTAssertNil(presenter.selectedMatch)
    }

    func testSelectionReturnsToTheTopWhenTheQueryChanges() {
        // The ranking has moved, so keeping the offset would keep a row the
        // user never chose.
        var presenter = presenter(["alpha.swift", "beta.swift"])
        presenter.moveSelection(by: 1)
        presenter.updateQuery("a")
        XCTAssertEqual(presenter.selectedIndex, 0)
    }

    func testClickingOutsideTheResultRangeClearsTheSelection() {
        var presenter = presenter(["a.swift"])
        presenter.select(row: 7)
        XCTAssertNil(presenter.selectedIndex)
    }

    // MARK: - Activation

    func testReturnInsertsAnAbsolutePathAndCommandReturnOpensTheEditor() {
        let presenter = presenter(["src/main.swift"])
        XCTAssertEqual(
            presenter.outcome(for: .insertPath),
            .insertPath("/projects/demo/src/main.swift")
        )
        XCTAssertEqual(
            presenter.outcome(for: .openInEditor),
            .openInEditor(URL(fileURLWithPath: "/projects/demo/src/main.swift"))
        )
    }

    func testTheUnmodifiedReturnKeyInsertsThePath() {
        // This is a terminal: the reason to find a file by name is nearly
        // always that a command is waiting for it at the prompt.
        XCTAssertEqual(
            ProjectFileQuickOpenActivation.forReturnKey(commandModifierHeld: false),
            .insertPath
        )
        XCTAssertEqual(
            ProjectFileQuickOpenActivation.forReturnKey(commandModifierHeld: true),
            .openInEditor
        )
    }

    func testActivatingWithNothingSelectedProducesNoOutcome() {
        var presenter = presenter(["a.swift"])
        presenter.updateQuery("zzz")
        XCTAssertNil(presenter.outcome(for: .insertPath))
        XCTAssertNil(presenter.outcome(for: .openInEditor))
    }

    // MARK: - Result caps

    func testTheVisibleCapLimitsRowsButTheFooterStillCountsEveryMatch() {
        var presenter = presenter(
            (0..<10).map { "src/main\($0).swift" },
            visibleLimit: 3
        )
        presenter.updateQuery("main")
        XCTAssertEqual(presenter.visibleMatches.count, 3)
        XCTAssertEqual(
            presenter.status,
            .results(source: .ripgrep, isListingTruncated: false, shownCOUNT: 3, totalCOUNT: 10)
        )
    }

    func testAnOverLongQueryReturnsNothingInsteadOfRankingIt() {
        // A pasted file's worth of text cannot be a path, and ranking it
        // against every entry is the one way this palette can be made to stall.
        var presenter = ProjectFileQuickOpenPresenter(
            rootDirectory: root,
            listing: listing(["a.swift"]),
            queryLimit: 4
        )
        presenter.updateQuery(String(repeating: "a", count: 5))
        XCTAssertEqual(presenter.visibleMatches, [])
        XCTAssertNil(presenter.selectedIndex)
    }

    // MARK: - Footer

    func testTheFooterNamesTheFallbackScanEvenWhenItWasNotTruncated() {
        // A complete-looking list that quietly skipped a gitignored directory
        // is exactly the case where the user needs to know which enumerator
        // answered, so the source is named whether or not the budget ran out.
        var presenter = ProjectFileQuickOpenPresenter(
            rootDirectory: root,
            listing: listing(["a.swift"], source: .directoryWalk, isTruncated: false)
        )
        presenter.updateQuery("a")

        let footer = ProjectFileQuickOpenCopy.footer(for: presenter.status, language: .english)
        XCTAssertTrue(
            footer.contains(AppLocalization.string(.openProjectFileWithoutRipgrep, language: .english))
        )
        XCTAssertFalse(
            footer.contains(AppLocalization.string(.openProjectFileTruncated, language: .english))
        )
    }

    func testTheFooterReportsBothTheFallbackAndTheTruncationWhenBothApply() {
        var presenter = ProjectFileQuickOpenPresenter(
            rootDirectory: root,
            listing: listing(["a.swift"], source: .directoryWalk, isTruncated: true)
        )
        presenter.updateQuery("a")

        let footer = ProjectFileQuickOpenCopy.footer(for: presenter.status, language: .english)
        XCTAssertTrue(
            footer.contains(AppLocalization.string(.openProjectFileWithoutRipgrep, language: .english))
        )
        XCTAssertTrue(
            footer.contains(AppLocalization.string(.openProjectFileTruncated, language: .english))
        )
    }

    func testARipgrepScanSaysNothingAboutItsSource() {
        // Nothing is wrong, so nothing is reported. The footer is a caveat
        // line, not a status line.
        var presenter = presenter(["a.swift"])
        presenter.updateQuery("a")

        let footer = ProjectFileQuickOpenCopy.footer(for: presenter.status, language: .english)
        XCTAssertFalse(
            footer.contains(AppLocalization.string(.openProjectFileWithoutRipgrep, language: .english))
        )
    }

    func testEveryFooterStateHasCopyInEveryLanguage() {
        let states: [ProjectFileQuickOpenStatus] = [
            .scanning,
            .emptyProject,
            .noMatches,
            .results(source: .ripgrep, isListingTruncated: false, shownCOUNT: 1, totalCOUNT: 1),
            .results(source: .directoryWalk, isListingTruncated: true, shownCOUNT: 1, totalCOUNT: 9),
        ]
        for language in AppLanguage.allCases {
            for state in states {
                XCTAssertFalse(
                    ProjectFileQuickOpenCopy.footer(for: state, language: language).isEmpty,
                    "\(state) has no copy in \(language)"
                )
            }
        }
    }

    // MARK: - Row copy

    func testARowSplitsTheNameFromTheDirectoryHoldingIt() {
        let nested = ProjectFileRowCopy(relativePath: "Sources/KurottyApp/Main.swift")
        XCTAssertEqual(nested.filename, "Main.swift")
        XCTAssertEqual(nested.directory, "Sources/KurottyApp")

        let root = ProjectFileRowCopy(relativePath: "Package.swift")
        XCTAssertEqual(root.filename, "Package.swift")
        XCTAssertEqual(root.directory, "")
    }
}
