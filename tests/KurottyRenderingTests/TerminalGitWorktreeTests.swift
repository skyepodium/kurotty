import AppKit
import XCTest
@testable import KurottyApp

/// Worktree collector stand-in for the status bar. Completes synchronously with
/// a fixture snapshot so the segment can be driven without a repository.
@MainActor
final class StubGitWorktreeProvider: TerminalGitWorktreeProviding {
    var snapshot: TerminalGitWorktreeSnapshot?
    private(set) var requestedDirectoryPaths: [String] = []
    private(set) var cancelCount = 0

    init(snapshot: TerminalGitWorktreeSnapshot?) {
        self.snapshot = snapshot
    }

    func requestSnapshot(
        workingDirectoryPath: String,
        completion: @escaping @MainActor (TerminalGitWorktreeSnapshot?) -> Void
    ) {
        requestedDirectoryPaths.append(workingDirectoryPath)
        completion(snapshot)
    }

    func cancelPendingRequests() {
        cancelCount += 1
    }
}

/// Git worktree awareness.
///
/// The porcelain parser, the containment rules, the dirty predicate, the row
/// builder, and the segment copy are pure functions, so most of this file never
/// runs `git`. The runner tests are the exception on purpose: they build a real
/// repository with real linked worktrees and assert against real output, which
/// is the only way to know the parser matches the format git actually prints.
final class TerminalGitWorktreeTests: XCTestCase {
    /// The bar holds its data source weakly; these keep the stubs alive.
    @MainActor private var retainedDataSources: [StubStatusBarDataSource] = []

    private enum Fixture {
        static let mainPath = "/Users/example/repo"
        static let featurePath = "/Users/example/repo-feature"
        static let spacedPath = "/Users/example/feature one"
        static let detachedPath = "/Users/example/repo-detached"
        static let barePath = "/Users/example/repo.git"
        static let headSHA = "6104196732d40f8ecb845d575c5d1c617fc6c8f5"
        static let shortHeadSHA = "6104196"
        static let mainBranch = "refs/heads/main"
        static let featureBranch = "refs/heads/feature/one"
        static let lockReason = "in review by agent"
        static let paneIdentifier = "pane-A"
        static let paneTitle = "~/repo (-zsh)"
        static let paneProcess: pid_t = 4242
        static let snapshotDirectoryEnvironmentKey = "KUROTTY_SNAPSHOT_DIR"
        static let snapshotWidthPX: CGFloat = 900
        static let snapshotHeightPX: CGFloat = 260
    }

    /// Real output shape, captured verbatim from `git worktree list --porcelain`
    /// on a repository built by `makeRepositoryWithWorktrees()`.
    private enum Porcelain {
        static let mainAndLinked = """
        worktree \(Fixture.mainPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.mainBranch)

        worktree \(Fixture.spacedPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.featureBranch)

        """

        static let detachedAndLocked = """
        worktree \(Fixture.mainPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.mainBranch)

        worktree \(Fixture.detachedPath)
        HEAD \(Fixture.headSHA)
        detached
        locked \(Fixture.lockReason)

        """

        static let bare = """
        worktree \(Fixture.barePath)
        bare

        worktree \(Fixture.mainPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.mainBranch)

        """
    }

    // MARK: - Porcelain parsing

    func testParsesTheMainWorktreeAndOneLinkedWorktree() throws {
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: Porcelain.mainAndLinked)

        XCTAssertEqual(worktrees.count, 2)
        let main = try XCTUnwrap(worktrees.first)
        XCTAssertEqual(main.path, Fixture.mainPath)
        XCTAssertEqual(main.headSHA, Fixture.headSHA)
        XCTAssertEqual(main.branchName, "main")
        // Git lists the main worktree first; nothing else marks it.
        XCTAssertTrue(main.isMain)
        XCTAssertFalse(main.isDetached)
        XCTAssertFalse(main.isBare)
        XCTAssertFalse(main.isLocked)

        let linked = try XCTUnwrap(worktrees.last)
        XCTAssertFalse(linked.isMain)
        XCTAssertEqual(linked.branchName, "feature/one")
    }

    func testParsesPathsContainingSpacesVerbatim() throws {
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: Porcelain.mainAndLinked)

        let linked = try XCTUnwrap(worktrees.last)
        XCTAssertEqual(linked.path, Fixture.spacedPath)
        XCTAssertEqual(linked.directoryName, "feature one")
    }

    func testParsesADetachedHeadWorktree() throws {
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: Porcelain.detachedAndLocked)

        let detached = try XCTUnwrap(worktrees.last)
        XCTAssertTrue(detached.isDetached)
        XCTAssertNil(detached.branchReference)
        XCTAssertNil(detached.branchName)
        XCTAssertEqual(detached.shortHeadSHA, Fixture.shortHeadSHA)
    }

    func testParsesALockedWorktreeWithAndWithoutAReason() throws {
        let withReason = try XCTUnwrap(
            GitWorktreeListParser.parse(porcelainOutput: Porcelain.detachedAndLocked).last
        )
        XCTAssertTrue(withReason.isLocked)
        XCTAssertEqual(withReason.lockReason, Fixture.lockReason)

        let withoutReason = try XCTUnwrap(GitWorktreeListParser.parse(porcelainOutput: """
        worktree \(Fixture.mainPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.mainBranch)
        locked

        """).first)
        XCTAssertTrue(withoutReason.isLocked)
        XCTAssertNil(withoutReason.lockReason)
    }

    func testParsesABareRepositoryRecordWithoutAHead() throws {
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: Porcelain.bare)

        let bare = try XCTUnwrap(worktrees.first)
        XCTAssertTrue(bare.isBare)
        XCTAssertTrue(bare.isMain)
        XCTAssertNil(bare.headSHA)
        XCTAssertNil(bare.branchName)
        XCTAssertFalse(try XCTUnwrap(worktrees.last).isBare)
    }

    func testParsesAPrunableWorktree() throws {
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: """
        worktree \(Fixture.mainPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.mainBranch)

        worktree \(Fixture.featurePath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.featureBranch)
        prunable gitdir file points to non-existent location

        """)

        XCTAssertTrue(try XCTUnwrap(worktrees.last).isPrunable)
        XCTAssertFalse(try XCTUnwrap(worktrees.first).isPrunable)
    }

    func testParserToleratesAMissingTrailingBlankLineAndUnknownAttributes() throws {
        let worktrees = GitWorktreeListParser.parse(porcelainOutput: """
        worktree \(Fixture.mainPath)
        HEAD \(Fixture.headSHA)
        branch \(Fixture.mainBranch)
        somethingNewerGitPrints value
        """)

        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(try XCTUnwrap(worktrees.first).branchName, "main")
    }

    func testParserReturnsNothingForEmptyOutput() {
        XCTAssertTrue(GitWorktreeListParser.parse(porcelainOutput: "").isEmpty)
        XCTAssertTrue(GitWorktreeListParser.parse(porcelainOutput: "\n\n").isEmpty)
    }

    // MARK: - Containment

    func testDeepestWorktreeWinsForANestedCheckout() throws {
        let outer = GitWorktree(path: Fixture.mainPath, isMain: true)
        let nested = GitWorktree(path: Fixture.mainPath + "/nested-worktree")

        let located = GitWorktreeLocator.worktree(
            containing: Fixture.mainPath + "/nested-worktree/Sources",
            in: [outer, nested]
        )

        XCTAssertEqual(try XCTUnwrap(located).path, nested.path)
    }

    func testContainmentRespectsPathComponentBoundaries() {
        let worktrees = [GitWorktree(path: Fixture.mainPath, isMain: true)]

        XCTAssertNotNil(GitWorktreeLocator.worktree(containing: Fixture.mainPath, in: worktrees))
        XCTAssertNotNil(GitWorktreeLocator.worktree(containing: Fixture.mainPath + "/", in: worktrees))
        XCTAssertNotNil(GitWorktreeLocator.worktree(containing: Fixture.mainPath + "/Sources", in: worktrees))
        // A sibling that merely shares a prefix is a different directory.
        XCTAssertNil(GitWorktreeLocator.worktree(containing: Fixture.mainPath + "-feature", in: worktrees))
    }

    func testDirectoryOutsideEveryWorktreeBelongsToNone() {
        let worktrees = [
            GitWorktree(path: Fixture.mainPath, isMain: true),
            GitWorktree(path: Fixture.featurePath),
        ]

        XCTAssertNil(GitWorktreeLocator.worktree(containing: "/Users/example/elsewhere", in: worktrees))
        XCTAssertNil(GitWorktreeLocator.worktree(containing: "", in: worktrees))
        XCTAssertNil(GitWorktreeLocator.worktree(containing: "   ", in: worktrees))
    }

    func testBareRecordsNeverContainADirectory() {
        let worktrees = [GitWorktree(path: Fixture.barePath, isBare: true, isMain: true)]

        XCTAssertNil(GitWorktreeLocator.worktree(containing: Fixture.barePath, in: worktrees))
    }

    // MARK: - Dirty state

    func testDirtyStateFollowsPorcelainStatusOutput() {
        XCTAssertFalse(GitWorktreeDirtyState.isDirty(porcelainZOutput: ""))
        XCTAssertFalse(GitWorktreeDirtyState.isDirty(porcelainZOutput: "\n"))
        XCTAssertTrue(GitWorktreeDirtyState.isDirty(porcelainZOutput: " M Sources/App.swift\u{0}"))
        XCTAssertTrue(GitWorktreeDirtyState.isDirty(porcelainZOutput: "?? new file.txt\u{0}"))
    }

    // MARK: - Rows and session attribution

    func testRowsDropBareRecordsAndMarkTheCurrentWorktree() throws {
        let snapshot = TerminalGitWorktreeSnapshot(
            worktrees: [
                GitWorktree(path: Fixture.barePath, isBare: true, isMain: true),
                GitWorktree(path: Fixture.mainPath, branchReference: Fixture.mainBranch),
                GitWorktree(path: Fixture.featurePath, branchReference: Fixture.featureBranch),
            ],
            dirtyPaths: [Fixture.featurePath],
            currentWorktreePath: Fixture.featurePath
        )

        let rows = GitWorktreeRowBuilder.rows(snapshot: snapshot, records: [])

        XCTAssertEqual(rows.map(\.worktree.path), [Fixture.mainPath, Fixture.featurePath])
        XCTAssertFalse(try XCTUnwrap(rows.first).isDirty)
        XCTAssertTrue(try XCTUnwrap(rows.last).isDirty)
        XCTAssertTrue(try XCTUnwrap(rows.last).isCurrent)
        XCTAssertFalse(try XCTUnwrap(rows.first).isCurrent)
    }

    func testEachAgentSessionIsCountedForExactlyOneWorktree() throws {
        let nestedPath = Fixture.mainPath + "/nested"
        let snapshot = TerminalGitWorktreeSnapshot(
            worktrees: [
                GitWorktree(path: Fixture.mainPath, branchReference: Fixture.mainBranch, isMain: true),
                GitWorktree(path: nestedPath, branchReference: Fixture.featureBranch),
            ],
            dirtyPaths: [],
            currentWorktreePath: Fixture.mainPath
        )
        let records = [
            makeSessionRecord(sessionID: "a", cwd: Fixture.mainPath),
            makeSessionRecord(sessionID: "b", cwd: Fixture.mainPath + "/Sources"),
            // Inside both the main checkout and the nested worktree: only the
            // deepest one may claim it.
            makeSessionRecord(sessionID: "c", cwd: nestedPath + "/Sources"),
            makeSessionRecord(sessionID: "d", cwd: "/Users/example/elsewhere"),
        ]

        let rows = GitWorktreeRowBuilder.rows(snapshot: snapshot, records: records)

        XCTAssertEqual(try XCTUnwrap(rows.first).agentSessionCount, 2)
        XCTAssertEqual(try XCTUnwrap(rows.last).agentSessionCount, 1)
    }

    // MARK: - Segment composition

    func testSegmentSummaryNamesTheCurrentBranchAndCountsWorktrees() {
        let summary = TerminalStatusBarWorktreeComposer.summary(
            snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath),
            language: .english
        )

        XCTAssertTrue(summary.isPresent)
        XCTAssertEqual(summary.name, "feature/one")
        XCTAssertEqual(summary.displayText, "feature/one")
        XCTAssertFalse(summary.isMain)
        XCTAssertEqual(summary.worktreeCount, 2)
        XCTAssertTrue(summary.tooltip.contains(Fixture.featurePath))
        XCTAssertTrue(summary.tooltip.contains("Linked worktree"))
    }

    func testSegmentSummaryMarksUncommittedChanges() {
        let summary = TerminalStatusBarWorktreeComposer.summary(
            snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath, dirtyPaths: [Fixture.featurePath]),
            language: .english
        )

        XCTAssertTrue(summary.isDirty)
        XCTAssertEqual(summary.displayText, "feature/one*")
        XCTAssertTrue(summary.tooltip.contains("Uncommitted changes"))
    }

    func testSegmentSummaryIsAbsentWithoutARepositoryOrACurrentWorktree() {
        XCTAssertFalse(TerminalStatusBarWorktreeComposer.summary(snapshot: nil, language: .english).isPresent)
        XCTAssertFalse(TerminalStatusBarWorktreeComposer.summary(
            snapshot: makeSnapshot(currentWorktreePath: nil),
            language: .english
        ).isPresent)
    }

    func testDetachedWorktreeIsNamedByItsShortCommit() {
        let snapshot = TerminalGitWorktreeSnapshot(
            worktrees: [GitWorktree(path: Fixture.detachedPath, headSHA: Fixture.headSHA, isDetached: true, isMain: true)],
            dirtyPaths: [],
            currentWorktreePath: Fixture.detachedPath
        )

        XCTAssertEqual(
            TerminalStatusBarWorktreeComposer.summary(snapshot: snapshot, language: .english).name,
            "\(Fixture.shortHeadSHA) · detached"
        )
        XCTAssertEqual(
            TerminalStatusBarWorktreeComposer.summary(snapshot: snapshot, language: .japanese).name,
            "\(Fixture.shortHeadSHA) · デタッチ"
        )
    }

    func testRowDetailIsLocalized() {
        let row = GitWorktreeRow(
            worktree: GitWorktree(path: Fixture.mainPath, branchReference: Fixture.mainBranch, isLocked: true, isMain: true),
            isDirty: true,
            agentSessionCount: 3,
            isCurrent: false
        )

        XCTAssertEqual(TerminalStatusBarWorktreeText.rowName(for: row, language: .english), "main*")
        XCTAssertEqual(
            TerminalStatusBarWorktreeText.rowDetail(for: row, language: .english),
            "main · locked · 3 agent sessions"
        )
        XCTAssertEqual(
            TerminalStatusBarWorktreeText.rowDetail(for: row, language: .korean),
            "메인 · 잠김 · 에이전트 세션 3개"
        )
        XCTAssertEqual(
            TerminalStatusBarWorktreeText.rowDetail(for: row, language: .japanese),
            "メイン · ロック中 · エージェントセッション 3 件"
        )
    }

    func testSingleSessionRowDetailUsesTheSingularEnglishForm() {
        let row = GitWorktreeRow(
            worktree: GitWorktree(path: Fixture.featurePath, branchReference: Fixture.featureBranch),
            isDirty: false,
            agentSessionCount: 1,
            isCurrent: false
        )

        XCTAssertEqual(TerminalStatusBarWorktreeText.rowDetail(for: row, language: .english), "1 agent session")
        XCTAssertEqual(TerminalStatusBarWorktreeText.rowDetail(for: row, language: .korean), "에이전트 세션 1개")
    }

    func testRowWithoutSessionsOrTagsHasNoDetail() {
        let row = GitWorktreeRow(
            worktree: GitWorktree(path: Fixture.featurePath, branchReference: Fixture.featureBranch),
            isDirty: false,
            agentSessionCount: 0,
            isCurrent: true
        )

        XCTAssertEqual(TerminalStatusBarWorktreeText.rowDetail(for: row, language: .english), "")
    }

    func testEveryWorktreeStringIsTranslatedInEveryLanguage() {
        let keys: [L10nKey] = [
            .statusBarWorktreeTitle, .statusBarWorktreeMainTag, .statusBarWorktreeMainDescription,
            .statusBarWorktreeLinkedDescription, .statusBarWorktreeDetached, .statusBarWorktreeLocked,
            .statusBarWorktreeDirtyDescription, .statusBarWorktreeSessionCount,
            .statusBarWorktreeSessionCountOne, .statusBarWorktreeChangeDirectory, .statusBarNoWorktrees,
        ]

        for language in AppLanguage.allCases {
            for key in keys {
                XCTAssertTrue(
                    AppLocalization.hasTranslation(for: key, language: language),
                    "Missing \(language.rawValue) translation for \(key.rawValue)"
                )
            }
        }
    }

    // MARK: - Change-directory command

    func testChangeDirectoryCommandQuotesThePathAndNeverExecutes() {
        let spaced = GitWorktreeChangeDirectoryCommand.command(
            for: GitWorktree(path: Fixture.spacedPath)
        )
        let apostrophe = GitWorktreeChangeDirectoryCommand.command(
            for: GitWorktree(path: "/Users/example/it's here")
        )

        XCTAssertEqual(spaced, "cd '/Users/example/feature one'")
        XCTAssertEqual(apostrophe, "cd '/Users/example/it'\\''s here'")
        XCTAssertFalse(spaced.hasSuffix("\n"))
    }

    // MARK: - Segment view

    @MainActor
    func testSegmentHidesItselfOutsideARepository() {
        let segmentView = TerminalStatusBarWorktreeSegmentView(frame: .zero)

        segmentView.update(summary: .absent, visibility: .full)

        XCTAssertTrue(segmentView.isHidden)
    }

    @MainActor
    func testSegmentIsDroppedWholeAtNarrowWidths() {
        let segmentView = TerminalStatusBarWorktreeSegmentView(frame: .zero)
        let summary = TerminalStatusBarWorktreeComposer.summary(
            snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath),
            language: .english
        )

        segmentView.update(summary: summary, visibility: .full)
        XCTAssertFalse(segmentView.isHidden)

        segmentView.update(
            summary: summary,
            visibility: TerminalStatusBarLayoutPolicy.visibility(
                barWidthPX: DesignTokens.Component.StatusBar.agentDetailBreakpointPX - 1
            )
        )
        XCTAssertTrue(segmentView.isHidden)
    }

    func testWorktreeSegmentSurvivesOnlyAtTheWidestBreakpoint() {
        XCTAssertTrue(TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 1_200).showsWorktree)
        XCTAssertTrue(TerminalStatusBarLayoutPolicy.visibility(
            barWidthPX: DesignTokens.Component.StatusBar.agentDetailBreakpointPX
        ).showsWorktree)
        XCTAssertFalse(TerminalStatusBarLayoutPolicy.visibility(
            barWidthPX: DesignTokens.Component.StatusBar.agentDetailBreakpointPX - 1
        ).showsWorktree)
    }

    // MARK: - Bar integration

    @MainActor
    func testBarRendersTheWorktreeOfTheActivePaneDirectory() {
        let provider = StubGitWorktreeProvider(snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath))
        let statusBarView = makeStatusBarView(provider: provider, workingDirectoryPath: Fixture.featurePath)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.snapshotWidthPX, height: 400))

        statusBarView.attach(to: containerView)
        containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(provider.requestedDirectoryPaths, [Fixture.featurePath])
        XCTAssertTrue(statusBarView.currentWorktreeSummary.isPresent)
        XCTAssertEqual(statusBarView.currentWorktreeSummary.name, "feature/one")
    }

    /// A per-prompt directory notification must not turn into a `git` process
    /// per command.
    @MainActor
    func testUnchangedWorkingDirectoryIsNotLookedUpAgain() {
        let provider = StubGitWorktreeProvider(snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath))
        let statusBarView = makeStatusBarView(provider: provider, workingDirectoryPath: Fixture.featurePath)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.snapshotWidthPX, height: 400))
        statusBarView.attach(to: containerView)

        statusBarView.refreshWorktreeSegment()
        statusBarView.refreshWorktreeSegment()

        XCTAssertEqual(provider.requestedDirectoryPaths.count, 1)

        statusBarView.refreshWorktreeSegment(forcesReload: true)
        XCTAssertEqual(provider.requestedDirectoryPaths.count, 2)
    }

    /// An SSH pane reports a directory on another machine. A local repository
    /// that happens to share that path must never be described as the pane's
    /// worktree.
    @MainActor
    func testRemoteWorkingDirectoryIsNeverLookedUpLocally() {
        let provider = StubGitWorktreeProvider(snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath))
        let statusBarView = makeStatusBarView(
            provider: provider,
            workingDirectoryPath: Fixture.featurePath,
            isWorkingDirectoryRemote: true
        )
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.snapshotWidthPX, height: 400))

        statusBarView.attach(to: containerView)
        containerView.layoutSubtreeIfNeeded()

        XCTAssertTrue(provider.requestedDirectoryPaths.isEmpty)
        XCTAssertFalse(statusBarView.currentWorktreeSummary.isPresent)
    }

    @MainActor
    func testBarKeepsTheWorktreeSegmentBetweenTheAgentAndResourceSegments() throws {
        let provider = StubGitWorktreeProvider(snapshot: makeSnapshot(currentWorktreePath: Fixture.featurePath))
        let statusBarView = makeStatusBarView(provider: provider, workingDirectoryPath: Fixture.featurePath)
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: Fixture.snapshotWidthPX, height: 400))
        statusBarView.attach(to: containerView)
        containerView.layoutSubtreeIfNeeded()

        let segments = statusBarView.subviews.compactMap { $0 as? TerminalStatusBarSegmentView }
        let worktreeSegment = try XCTUnwrap(segments.compactMap { $0 as? TerminalStatusBarWorktreeSegmentView }.first)
        let agentSegment = try XCTUnwrap(segments.compactMap { $0 as? TerminalStatusBarAgentSegmentView }.first)
        let resourceSegment = try XCTUnwrap(segments.compactMap { $0 as? TerminalStatusBarResourceSegmentView }.first)

        XCTAssertEqual(segments.count, 3)
        XCTAssertGreaterThanOrEqual(worktreeSegment.frame.minX, agentSegment.frame.maxX)
        XCTAssertLessThanOrEqual(worktreeSegment.frame.maxX, resourceSegment.frame.minX)
    }

    /// Selecting a worktree inserts `cd '<path>'` at the prompt. There is no
    /// execute path at all.
    @MainActor
    func testSelectingAWorktreeRowReportsAnInsertOnlyChangeDirectory() throws {
        let rows = GitWorktreeRowBuilder.rows(
            snapshot: makeSnapshot(currentWorktreePath: Fixture.mainPath),
            records: []
        )
        let listView = TerminalStatusBarWorktreeListView(rows: rows, theme: .dark)
        var selected: GitWorktree?
        listView.onChangeDirectory = { selected = $0 }

        let buttons = Self.buttons(in: listView)
        // Only the worktrees the pane is not already in offer the action.
        XCTAssertEqual(buttons.count, 1)
        try XCTUnwrap(buttons.first).performClick(nil)

        XCTAssertEqual(try XCTUnwrap(selected).path, Fixture.featurePath)
        XCTAssertEqual(
            GitWorktreeChangeDirectoryCommand.command(for: try XCTUnwrap(selected)),
            "cd '\(Fixture.featurePath)'"
        )
    }

    @MainActor
    func testEmptyWorktreeListExplainsItself() {
        let listView = TerminalStatusBarWorktreeListView(rows: [], theme: .dark)

        let labels = Self.textFields(in: listView).map(\.stringValue)

        XCTAssertTrue(labels.contains(AppLocalization.string(.statusBarWorktreeTitle)))
        XCTAssertTrue(labels.contains(AppLocalization.string(.statusBarNoWorktrees)))
    }

    // MARK: - Real repository

    /// Behavioral evidence that the parser matches what git actually prints:
    /// a real repository with a linked worktree whose path contains a space, a
    /// detached and locked worktree, and a subdirectory the runner has to
    /// resolve back to its own worktree.
    func testRunnerCollectsARealRepositoryWithLinkedWorktrees() throws {
        try skipWithoutGit()
        let repository = try makeRepositoryWithWorktrees()
        defer { try? FileManager.default.removeItem(at: repository.root) }

        let nested = repository.spacedWorktree.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let snapshot = try XCTUnwrap(TerminalGitWorktreeRunner.collectSnapshot(workingDirectoryPath: nested.path))

        XCTAssertEqual(snapshot.worktrees.count, 3)
        XCTAssertTrue(try XCTUnwrap(snapshot.worktrees.first).isMain)
        XCTAssertEqual(try XCTUnwrap(snapshot.worktrees.first).path, repository.mainWorktree.path)
        XCTAssertEqual(try XCTUnwrap(snapshot.worktrees.first).branchName, repository.mainBranch)
        // The runner resolves the *containing* worktree, not the main checkout.
        XCTAssertEqual(snapshot.currentWorktreePath, repository.spacedWorktree.path)
        XCTAssertEqual(try XCTUnwrap(snapshot.currentWorktree).branchName, "feature-one")

        let detached = try XCTUnwrap(snapshot.worktrees.first { $0.path == repository.detachedWorktree.path })
        XCTAssertTrue(detached.isDetached)
        XCTAssertTrue(detached.isLocked)
        XCTAssertNil(detached.branchName)
        XCTAssertEqual(detached.shortHeadSHA?.count, 7)

        // Clean until something is written, then dirty.
        XCTAssertTrue(snapshot.dirtyPaths.isEmpty)
        try "changed\n".write(
            to: repository.spacedWorktree.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        let dirtySnapshot = try XCTUnwrap(
            TerminalGitWorktreeRunner.collectSnapshot(workingDirectoryPath: repository.spacedWorktree.path)
        )
        XCTAssertEqual(dirtySnapshot.dirtyPaths, [repository.spacedWorktree.path])
    }

    func testRunnerReturnsNothingOutsideAnyRepository() throws {
        try skipWithoutGit()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-worktree-non-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertNil(TerminalGitWorktreeRunner.collectSnapshot(workingDirectoryPath: temporaryRoot.path))
        XCTAssertNil(TerminalGitWorktreeRunner.collectSnapshot(workingDirectoryPath: "/nonexistent-\(UUID().uuidString)"))
    }

    // MARK: - Visual evidence

    /// Renders the bar and the worktree popover offscreen in both chrome
    /// themes. The PNGs are written only when `KUROTTY_SNAPSHOT_DIR` is set, so
    /// the suite stays side-effect free while the same code path produces the
    /// review images.
    @MainActor
    func testWorktreeSurfacesRenderInDarkAndLightThemes() throws {
        // Review images must not depend on the developer's system language.
        let previousPreference = AppLocalization.preference
        AppLocalization.preference = .english
        defer {
            AppLocalization.preference = previousPreference
        }
        for (theme, name) in [(DesignTokens.ChromeTheme.dark, "dark"), (DesignTokens.ChromeTheme.light, "light")] {
            let snapshotView = try makeSnapshotView(theme: theme)
            let representation = try XCTUnwrap(
                snapshotView.bitmapImageRepForCachingDisplay(in: snapshotView.bounds)
            )
            snapshotView.cacheDisplay(in: snapshotView.bounds, to: representation)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

            XCTAssertGreaterThan(representation.pixelsWide, 0)
            XCTAssertGreaterThan(representation.pixelsHigh, 0)
            XCTAssertFalse(data.isEmpty)

            guard let directory = ProcessInfo.processInfo.environment[Fixture.snapshotDirectoryEnvironmentKey] else {
                continue
            }
            try data.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("status-bar-worktree-\(name).png"))
        }
    }

    /// The bar over one chrome background with the worktree popover above it,
    /// so one image shows both surfaces at their real sizes.
    @MainActor
    private func makeSnapshotView(theme: DesignTokens.ChromeTheme) throws -> NSView {
        let containerView = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Fixture.snapshotWidthPX,
            height: Fixture.snapshotHeightPX
        ))
        containerView.wantsLayer = true
        containerView.appearance = theme.windowAppearance
        containerView.layer?.backgroundColor = theme.surfaceCanvas.cgColor

        let snapshot = makeSnapshot(currentWorktreePath: Fixture.featurePath, dirtyPaths: [Fixture.featurePath])
        let provider = StubGitWorktreeProvider(snapshot: snapshot)
        let statusBarView = makeStatusBarView(provider: provider, workingDirectoryPath: Fixture.featurePath)
        statusBarView.applyChromeTheme(theme)
        statusBarView.attach(to: containerView)

        let rows = GitWorktreeRowBuilder.rows(snapshot: snapshot, records: [
            makeSessionRecord(sessionID: "a", cwd: Fixture.mainPath),
            makeSessionRecord(sessionID: "b", cwd: Fixture.featurePath),
            makeSessionRecord(sessionID: "c", cwd: Fixture.featurePath + "/Sources"),
        ])
        let listView = TerminalStatusBarWorktreeListView(rows: rows, theme: theme)
        listView.wantsLayer = true
        listView.appearance = theme.windowAppearance
        listView.layer?.backgroundColor = theme.surfaceRaised.cgColor
        listView.layer?.cornerRadius = DesignTokens.Component.StatusBar.segmentCornerRadiusPX
        listView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(listView)
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(
                equalTo: containerView.leadingAnchor,
                constant: DesignTokens.Component.StatusBar.horizontalInsetPX
            ),
            listView.bottomAnchor.constraint(
                equalTo: statusBarView.topAnchor,
                constant: -DesignTokens.Component.StatusBar.popoverInsetPX
            ),
        ])

        containerView.layoutSubtreeIfNeeded()
        return containerView
    }

    // MARK: - Fixtures

    private func makeSnapshot(
        currentWorktreePath: String?,
        dirtyPaths: Set<String> = []
    ) -> TerminalGitWorktreeSnapshot {
        TerminalGitWorktreeSnapshot(
            worktrees: [
                GitWorktree(path: Fixture.mainPath, headSHA: Fixture.headSHA, branchReference: Fixture.mainBranch, isMain: true),
                GitWorktree(path: Fixture.featurePath, headSHA: Fixture.headSHA, branchReference: Fixture.featureBranch),
            ],
            dirtyPaths: dirtyPaths,
            currentWorktreePath: currentWorktreePath
        )
    }

    private func makeSessionRecord(sessionID: String, cwd: String) -> AgentSessionRecord {
        AgentSessionRecord(
            agent: .claudeCode,
            sessionID: sessionID,
            title: "session",
            cwd: cwd,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            createdAt: Date(timeIntervalSince1970: 1_000),
            messageCount: 1,
            filePath: "/tmp/\(sessionID).jsonl"
        )
    }

    @MainActor
    private func makeStatusBarView(
        provider: StubGitWorktreeProvider,
        workingDirectoryPath: String,
        isWorkingDirectoryRemote: Bool = false
    ) -> TerminalStatusBarView {
        let dataSource = StubStatusBarDataSource(descriptors: [
            TerminalStatusBarPaneDescriptor(
                paneIdentifier: Fixture.paneIdentifier,
                title: Fixture.paneTitle,
                shellProcessIdentifier: Fixture.paneProcess,
                workingDirectoryPath: workingDirectoryPath,
                isWorkingDirectoryRemote: isWorkingDirectoryRemote
            ),
        ])
        let statusBarView = TerminalStatusBarView(
            registry: AgentActivityRegistry(),
            sessionIndexStore: AgentSessionIndexStore(
                isIndexingEnabled: false,
                observesSettingsChanges: false
            ),
            worktreeService: provider
        )
        statusBarView.areStatusHooksInstalledProvider = { false }
        statusBarView.dataSource = dataSource
        // The bar holds its data source weakly, so the test owns the stub.
        retainedDataSources.append(dataSource)
        addTeardownBlock { @MainActor in
            statusBarView.stopSampling()
        }
        return statusBarView
    }

    @MainActor
    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            guard let button = subview as? NSButton else {
                return buttons(in: subview)
            }
            return [button]
        }
    }

    @MainActor
    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            guard let field = subview as? NSTextField else {
                return textFields(in: subview)
            }
            return [field]
        }
    }

    // MARK: - Real repository fixtures

    private struct RepositoryFixture {
        let root: URL
        let mainWorktree: URL
        let spacedWorktree: URL
        let detachedWorktree: URL
        let mainBranch: String
    }

    private func skipWithoutGit() throws {
        guard runGit(arguments: ["--version"], in: FileManager.default.temporaryDirectory) != nil else {
            throw XCTSkip("git is unavailable on this machine")
        }
    }

    /// Builds a repository with the main checkout, a linked worktree whose path
    /// contains a space, and a locked detached worktree. Paths are resolved
    /// through the filesystem because git always reports resolved paths and the
    /// temporary directory is a symlink on macOS.
    private func makeRepositoryWithWorktrees() throws -> RepositoryFixture {
        let mainBranch = "trunk"
        let unresolvedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-worktree-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unresolvedRoot, withIntermediateDirectories: true)
        // The macOS temporary directory is reached through a symlink and git
        // always reports fully resolved paths. `resolvingSymlinksInPath()`
        // cannot be used here: it deliberately strips a leading `/private`,
        // which is the opposite of what git prints.
        let root = realPath(of: unresolvedRoot)
        let mainWorktree = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: mainWorktree, withIntermediateDirectories: true)
        try XCTUnwrap(runGit(arguments: ["init", "--initial-branch=\(mainBranch)"], in: mainWorktree))
        try "hello\n".write(
            to: mainWorktree.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try XCTUnwrap(runGit(arguments: ["add", "README.md"], in: mainWorktree))
        try XCTUnwrap(runGit(arguments: ["commit", "-m", "initial"], in: mainWorktree))

        let spacedWorktree = root.appendingPathComponent("feature one")
        try XCTUnwrap(runGit(
            arguments: ["worktree", "add", spacedWorktree.path, "-b", "feature-one"],
            in: mainWorktree
        ))
        let detachedWorktree = root.appendingPathComponent("detached")
        try XCTUnwrap(runGit(
            arguments: ["worktree", "add", "--detach", detachedWorktree.path, "HEAD"],
            in: mainWorktree
        ))
        try XCTUnwrap(runGit(
            arguments: ["worktree", "lock", "--reason", "in review by agent", detachedWorktree.path],
            in: mainWorktree
        ))
        return RepositoryFixture(
            root: root,
            mainWorktree: mainWorktree,
            spacedWorktree: spacedWorktree,
            detachedWorktree: detachedWorktree,
            mainBranch: mainBranch
        )
    }

    private func realPath(of url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else {
            return url
        }
        defer {
            free(resolved)
        }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// Hermetic git invocation: user and system configuration are excluded so a
    /// developer's global settings cannot change what the fixture repository
    /// looks like.
    private func runGit(arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "Kurotty Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@kurotty.invalid"
        environment["GIT_COMMITTER_NAME"] = "Kurotty Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@kurotty.invalid"
        process.environment = environment
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: outputData, encoding: .utf8)
    }
}
