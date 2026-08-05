import XCTest
@testable import KurottyApp

final class TerminalFileExplorerTests: XCTestCase {
    private enum Fixture {
        static let recordSeparator = "\u{0}"
        static let repositoryRootPath = "/Users/tester/dev/project"
        static let visitBudgetCount = 2
    }

    private func absolutePath(_ relativePath: String) -> String {
        Fixture.repositoryRootPath + "/" + relativePath
    }

    private func porcelainOutput(_ records: [String]) -> String {
        records.map { $0 + Fixture.recordSeparator }.joined()
    }

    // MARK: - Porcelain parser

    /// Re-pointed: the explorer's git column now distinguishes staged and
    /// conflicted work from an unstaged edit, so a record whose worktree letter
    /// is a space is staged rather than modified.
    func testParserClassifiesModifiedStagedUntrackedAndIgnoredRecords() {
        let output = porcelainOutput([
            " M Sources/App/File.swift",
            "M  Staged.swift",
            "A  Added.swift",
            "?? notes.txt",
            "!! .build/",
        ])
        let snapshot = GitPorcelainParser.parse(porcelainZOutput: output)
        XCTAssertEqual(snapshot.modifiedRelativePaths, ["Sources/App/File.swift"])
        XCTAssertEqual(snapshot.stagedRelativePaths, ["Staged.swift", "Added.swift"])
        XCTAssertEqual(snapshot.untrackedRelativePaths, ["notes.txt"])
        XCTAssertEqual(snapshot.ignoredRelativePaths, [".build"])
    }

    func testParserClassifiesUnmergedRecordsAsConflicted() {
        let output = porcelainOutput([
            "UU Both.swift",
            "AA AddedByBoth.swift",
            "DD DeletedByBoth.swift",
            "AU AddedByUs.swift",
            " M Plain.swift",
        ])
        let snapshot = GitPorcelainParser.parse(porcelainZOutput: output)
        XCTAssertEqual(
            snapshot.conflictedRelativePaths,
            ["Both.swift", "AddedByBoth.swift", "DeletedByBoth.swift", "AddedByUs.swift"]
        )
        XCTAssertEqual(snapshot.modifiedRelativePaths, ["Plain.swift"])
    }

    func testParserConsumesRenameOriginPathField() {
        let output = porcelainOutput([
            "R  NewName.swift",
            "OldName.swift",
            "?? extra.txt",
        ])
        let snapshot = GitPorcelainParser.parse(porcelainZOutput: output)
        // `R ` is an index-only change, so the rename lands in the staged list.
        XCTAssertEqual(snapshot.stagedRelativePaths, ["NewName.swift"])
        XCTAssertEqual(snapshot.untrackedRelativePaths, ["extra.txt"])
        XCTAssertFalse(snapshot.stagedRelativePaths.contains("OldName.swift"))
        XCTAssertFalse(snapshot.modifiedRelativePaths.contains("OldName.swift"))
        XCTAssertFalse(snapshot.untrackedRelativePaths.contains("OldName.swift"))
    }

    func testParserKeepsRawPathsWithSpacesAndQuotes() {
        let quotedName = "dir name/with \"quotes\".txt"
        let output = porcelainOutput(["?? " + quotedName])
        let snapshot = GitPorcelainParser.parse(porcelainZOutput: output)
        XCTAssertEqual(snapshot.untrackedRelativePaths, [quotedName])
    }

    func testParserHandlesEmptyAndMalformedOutput() {
        XCTAssertEqual(GitPorcelainParser.parse(porcelainZOutput: ""), .empty)
        let malformed = porcelainOutput(["M", ""])
        XCTAssertEqual(GitPorcelainParser.parse(porcelainZOutput: malformed), .empty)
    }

    // MARK: - Git overlay and ancestor propagation

    private func makeOverlay(
        modified: [String] = [],
        staged: [String] = [],
        conflicted: [String] = [],
        untracked: [String] = [],
        ignored: [String] = []
    ) -> FileExplorerGitOverlay {
        FileExplorerGitOverlay(
            repositoryRootPath: Fixture.repositoryRootPath,
            snapshot: GitStatusSnapshot(
                modifiedRelativePaths: modified,
                stagedRelativePaths: staged,
                conflictedRelativePaths: conflicted,
                untrackedRelativePaths: untracked,
                ignoredRelativePaths: ignored
            )
        )
    }

    func testModifiedStatusPropagatesToAncestorDirectories() {
        let overlay = makeOverlay(modified: ["Sources/App/File.swift"])
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources/App/File.swift")), .modified)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources/App")), .modified)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources")), .modified)
        XCTAssertNil(overlay.badge(forAbsolutePath: absolutePath("Other")))
    }

    func testModifiedWinsOverUntrackedAtSharedAncestors() {
        let overlay = makeOverlay(
            modified: ["Sources/A.swift"],
            untracked: ["Sources/New.swift", "docs/note.md"]
        )
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources")), .modified)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources/New.swift")), .untracked)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("docs")), .untracked)
    }

    /// Ancestor precedence is a single rank order, so a conflicted file always
    /// surfaces through the folders above it even when they also hold modified
    /// or staged work.
    func testAncestorPrecedenceOrdersConflictOverModifiedOverStagedOverUntracked() {
        let overlay = makeOverlay(
            modified: ["Sources/Modified.swift"],
            staged: ["Sources/Staged.swift", "staged-only/File.swift"],
            conflicted: ["Sources/Conflicted.swift"],
            untracked: ["Sources/New.swift"]
        )
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources")), .conflicted)
        XCTAssertEqual(
            overlay.badge(forAbsolutePath: absolutePath("Sources/Modified.swift")),
            .modified
        )
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources/Staged.swift")), .staged)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("Sources/New.swift")), .untracked)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath("staged-only")), .staged)
    }

    func testStagedOutranksUntrackedButNotModifiedAtSharedAncestors() {
        let stagedOverUntracked = makeOverlay(staged: ["dir/A.swift"], untracked: ["dir/B.swift"])
        XCTAssertEqual(stagedOverUntracked.badge(forAbsolutePath: absolutePath("dir")), .staged)

        let modifiedOverStaged = makeOverlay(modified: ["dir/A.swift"], staged: ["dir/B.swift"])
        XCTAssertEqual(modifiedOverStaged.badge(forAbsolutePath: absolutePath("dir")), .modified)
    }

    func testIgnoredDirectoryCoversDescendantsWithoutMarkingSiblings() {
        let overlay = makeOverlay(ignored: [".build"])
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath(".build")), .ignored)
        XCTAssertEqual(overlay.badge(forAbsolutePath: absolutePath(".build/debug/App.o")), .ignored)
        XCTAssertNil(overlay.badge(forAbsolutePath: absolutePath("Sources")))
    }

    func testOverlayReturnsNilForRootAndPathsOutsideRepository() {
        let overlay = makeOverlay(modified: ["File.swift"])
        XCTAssertNil(overlay.badge(forAbsolutePath: Fixture.repositoryRootPath))
        XCTAssertNil(overlay.badge(forAbsolutePath: "/Users/tester/elsewhere/File.swift"))
    }

    func testEmptyOverlayForNonRepositoryDirectoriesShowsNoBadges() {
        XCTAssertNil(FileExplorerGitOverlay.empty.badge(forAbsolutePath: absolutePath("File.swift")))
    }

    // MARK: - Sorting

    private func makeNode(_ relativePath: String, kind: FileExplorerNodeKind) -> FileExplorerNode {
        FileExplorerNode(url: URL(fileURLWithPath: absolutePath(relativePath)), kind: kind)
    }

    func testSortingPutsDirectoriesFirstThenAlphabetical() {
        let sorted = FileExplorerSorter.sorted([
            makeNode("zeta.txt", kind: .file),
            makeNode("alpha.txt", kind: .file),
            makeNode("Sources", kind: .directory),
            makeNode("Beta.txt", kind: .file),
            makeNode("docs", kind: .directory),
        ])
        XCTAssertEqual(sorted.map(\.name), ["docs", "Sources", "alpha.txt", "Beta.txt", "zeta.txt"])
    }

    // MARK: - Name filter and projection

    func testNameFilterMatchesSubstringCaseInsensitively() {
        XCTAssertTrue(FileExplorerNameFilter.matches(name: "TerminalModel.swift", query: "model"))
        XCTAssertFalse(FileExplorerNameFilter.matches(name: "TerminalModel.swift", query: "zzz"))
        XCTAssertFalse(FileExplorerNameFilter.matches(name: "TerminalModel.swift", query: "   "))
    }

    func testNameFilterMatchesFuzzySubsequence() {
        XCTAssertTrue(FileExplorerNameFilter.matches(name: "TerminalFileExplorer.swift", query: "tfe"))
        XCTAssertFalse(FileExplorerNameFilter.matches(name: "TerminalFileExplorer.swift", query: "xqz"))
    }

    private func fakeChildProvider(
        _ childrenByPath: [String: [FileExplorerNode]]
    ) -> (URL) -> [FileExplorerNode] {
        { url in childrenByPath[url.path] ?? [] }
    }

    func testFilterProjectionWalksTreeAndSkipsGitDirectory() {
        let rootURL = URL(fileURLWithPath: Fixture.repositoryRootPath)
        let provider = fakeChildProvider([
            Fixture.repositoryRootPath: [
                makeNode(".git", kind: .directory),
                makeNode("Sources", kind: .directory),
                makeNode("README.md", kind: .file),
            ],
            absolutePath("Sources"): [makeNode("Sources/Main.swift", kind: .file)],
            absolutePath(".git"): [makeNode(".git/main.lock", kind: .file)],
        ])
        let matches = FileExplorerFilterProjection.matches(
            rootDirectory: rootURL,
            query: "main",
            childProvider: provider
        )
        XCTAssertEqual(matches.map(\.relativeDisplayPath), ["Sources/Main.swift"])
    }

    func testFilterProjectionRespectsVisitBudget() {
        let rootURL = URL(fileURLWithPath: Fixture.repositoryRootPath)
        let provider = fakeChildProvider([
            Fixture.repositoryRootPath: [
                makeNode("match-a.txt", kind: .file),
                makeNode("match-b.txt", kind: .file),
                makeNode("match-c.txt", kind: .file),
            ],
        ])
        let matches = FileExplorerFilterProjection.matches(
            rootDirectory: rootURL,
            query: "match",
            childProvider: provider,
            maxVisitedEntryCount: Fixture.visitBudgetCount
        )
        XCTAssertEqual(matches.count, Fixture.visitBudgetCount)
    }

    func testFilterProjectionEmptyQueryReturnsNoMatches() {
        let rootURL = URL(fileURLWithPath: Fixture.repositoryRootPath)
        let provider = fakeChildProvider([
            Fixture.repositoryRootPath: [makeNode("README.md", kind: .file)],
        ])
        XCTAssertEqual(
            FileExplorerFilterProjection.matches(rootDirectory: rootURL, query: "", childProvider: provider),
            []
        )
    }

    // MARK: - Directory lister

    func testDirectoryListerNeverListsInsideGitDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-file-explorer-tests-\(UUID().uuidString)")
        let gitDirectory = temporaryRoot.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: gitDirectory.appendingPathComponent("HEAD").path,
            contents: Data()
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertEqual(FileExplorerDirectoryLister.listChildren(of: gitDirectory), [])
        let rootChildren = FileExplorerDirectoryLister.listChildren(of: temporaryRoot)
        XCTAssertEqual(rootChildren.map(\.name), [".git"])
        XCTAssertEqual(rootChildren.first?.kind, .directory)
    }

    // MARK: - Non-repository behavior

    func testGitStatusRunnerReturnsNilOutsideRepository() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-non-repo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertNil(TerminalGitStatusRunner.collectStatus(rootDirectoryPath: temporaryRoot.path))
    }
}
