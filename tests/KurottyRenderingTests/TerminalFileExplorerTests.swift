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

    // MARK: - Project icons

    func testProjectIconResolverPrefersAConventionalLocalImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let iconURL = root.appendingPathComponent("favicon.png")
        try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64)).write(to: iconURL)

        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .localFile(iconURL.standardizedFileURL)
        )
    }

    func testProjectIconResolverKeepsLocalImageAheadOfGitHubAvatar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let iconURL = root.appendingPathComponent("favicon.png")
        try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64)).write(to: iconURL)
        try """
        [remote "origin"]
            url = git@github.com:openai/codex.git
        """.write(to: gitDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .localFile(iconURL.standardizedFileURL)
        )
    }

    func testProjectIconResolverGeneratesALocalIdentityForARepository() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .generated(root.lastPathComponent)
        )
    }

    func testProjectIconResolverUsesGitHubOriginOwnerAvatar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [remote "origin"]
            url = git@github.com:openai/codex.git
        """.write(to: gitDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .githubAvatar(owner: "openai", fallbackLabel: root.lastPathComponent)
        )
    }

    func testProjectIconResolverPrefersUpstreamGitHubOwnerForAFork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [remote "origin"]
            url = https://github.com/local-user/codex.git
        [remote "upstream"]
            url = https://github.com/openai/codex.git
        """.write(to: gitDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .githubAvatar(owner: "openai", fallbackLabel: root.lastPathComponent)
        )
    }

    func testProjectIconResolverReadsTheCommonConfigForAGitWorktree() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        let root = container.appendingPathComponent("worktree", isDirectory: true)
        let commonGitDirectory = container.appendingPathComponent("main.git", isDirectory: true)
        let worktreeGitDirectory = commonGitDirectory
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: worktreeGitDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try "gitdir: \(worktreeGitDirectory.path)\n".write(
            to: root.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "../..\n".write(
            to: worktreeGitDirectory.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [remote "origin"]
            url = https://github.com/openai/codex.git
        """.write(
            to: commonGitDirectory.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .githubAvatar(owner: "openai", fallbackLabel: root.lastPathComponent)
        )
    }

    func testGitHubOwnerParserAcceptsHTTPSAndSSHButRejectsLookalikeHosts() {
        XCTAssertEqual(
            FileExplorerProjectIconResolver.githubOwner(
                fromRemoteURL: "https://github.com/openai/codex.git"
            ),
            "openai"
        )
        XCTAssertEqual(
            FileExplorerProjectIconResolver.githubOwner(
                fromRemoteURL: "git@github.com:openai/codex.git"
            ),
            "openai"
        )
        XCTAssertNil(
            FileExplorerProjectIconResolver.githubOwner(
                fromRemoteURL: "git@evilgithub.com:openai/codex.git"
            )
        )
    }

    func testProjectIconRasterValidationAcceptsGitHubJPEGResponses() {
        let jpegHeader = Data([0xff, 0xd8, 0xff, 0xdb, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(FileExplorerProjectIconResolver.isSupportedRasterImage(jpegHeader))
    }

    func testProjectIconResolverSkipsAnInvalidLocalImageBeforeGeneratedFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not an image".utf8).write(to: root.appendingPathComponent("favicon.png"))
        XCTAssertEqual(
            FileExplorerProjectIconResolver.source(for: root),
            .generated(root.lastPathComponent)
        )
    }

    @MainActor
    func testProjectRowUsesTheResolvedImageWhileNestedFoldersKeepSymbols() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let iconURL = root.appendingPathComponent("logo.png")
        try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64)).write(to: iconURL)
        let item = TerminalFileExplorerOutlineItem(
            node: FileExplorerNode(url: root, kind: .directory)
        )

        let projectCell = TerminalFileExplorerRowCellView(
            item: item,
            badge: nil,
            projectIconSource: .localFile(iconURL),
            chromeTheme: .light
        )
        let nestedCell = TerminalFileExplorerRowCellView(
            item: item,
            badge: nil,
            projectIconSource: nil,
            chromeTheme: .light
        )

        XCTAssertNotNil(projectCell.leadingIconImageForTesting)
        XCTAssertNotNil(nestedCell.leadingIconImageForTesting)
        XCTAssertTrue(projectCell.isDisplayingProjectIconForTesting)
        XCTAssertFalse(nestedCell.isDisplayingProjectIconForTesting)
    }

    @MainActor
    func testExpandedNestedRepositoryReceivesAProjectIdentitySource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-nested-project-icon-\(UUID().uuidString)")
        let group = root.appendingPathComponent("terminal", isDirectory: true)
        let repository = group.appendingPathComponent("orca", isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [remote "origin"]
            url = git@github.com:openai/orca.git
        """.write(to: gitDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let panel = TerminalFileExplorerPanelView(
            agentSessionIndexStore: AgentSessionIndexStore(
                homeDirectory: root,
                scanners: [],
                isIndexingEnabled: false,
                observesSettingsChanges: false
            )
        )
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        panel.update(rootDirectory: root)
        panel.layoutSubtreeIfNeeded()

        panel.expandRowForTesting(0)
        for _ in 0..<20 where panel.projectIconSourceForTesting(at: repository) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            panel.projectIconSourceForTesting(at: repository),
            .githubAvatar(owner: "openai", fallbackLabel: "orca")
        )
    }

    @MainActor
    func testGitHubAvatarLoaderShowsFallbackThenCachesRemoteImage() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let loader = FileExplorerProjectIconLoader(
            cacheDirectory: cacheDirectory,
            remoteDataLoader: { _ in imageData }
        )
        let callbacks = expectation(description: "generated fallback and remote avatar")
        callbacks.expectedFulfillmentCount = 2
        var deliveredImages = 0

        loader.load(.githubAvatar(owner: "openai", fallbackLabel: "codex")) { image in
            XCTAssertNotNil(image)
            deliveredImages += 1
            callbacks.fulfill()
        }

        await fulfillment(of: [callbacks], timeout: 1)
        XCTAssertEqual(deliveredImages, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cacheDirectory.appendingPathComponent("github-openai.png").path
            )
        )
    }

    @MainActor
    func testGitHubAvatarLoaderCoalescesProjectsOwnedByTheSameProfile() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-icon-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let remoteStarted = expectation(description: "one owner request")
        remoteStarted.expectedFulfillmentCount = 1
        let loader = FileExplorerProjectIconLoader(
            cacheDirectory: cacheDirectory,
            remoteDataLoader: { _ in
                remoteStarted.fulfill()
                try await Task.sleep(for: .milliseconds(20))
                return imageData
            }
        )
        let remoteImages = expectation(description: "both project rows upgrade")
        remoteImages.expectedFulfillmentCount = 2
        var firstCallbacks = 0
        var secondCallbacks = 0

        loader.load(.githubAvatar(owner: "openai", fallbackLabel: "codex")) { _ in
            firstCallbacks += 1
            if firstCallbacks == 2 { remoteImages.fulfill() }
        }
        loader.load(.githubAvatar(owner: "openai", fallbackLabel: "another-project")) { _ in
            secondCallbacks += 1
            if secondCallbacks == 2 { remoteImages.fulfill() }
        }

        await fulfillment(of: [remoteStarted, remoteImages], timeout: 1)
        XCTAssertEqual(firstCallbacks, 2)
        XCTAssertEqual(secondCallbacks, 2)
    }

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

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

// MARK: - Agent provenance rows

/// The explorer's agent-provenance column: a reserved slot before the git
/// column, a tooltip that names the session's prompt, and a transcript action
/// that is present only for files an agent actually wrote.
@MainActor
final class TerminalFileExplorerAgentProvenanceRowTests: XCTestCase {
    private enum RowFixture {
        static let rowWidthPX: CGFloat = 240
        static let prompt = "Document the provenance index"
        static let transcriptPath = "/Users/tester/.claude/projects/slug/session-1.jsonl"
    }

    private func touch(for url: URL, minutesAgo: Int = 90) -> AgentFileTouch {
        AgentFileTouch(
            agent: .claudeCode,
            sessionID: "session-1",
            absolutePath: url.standardizedFileURL.path,
            changedAt: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            kind: .edited,
            promptExcerpt: RowFixture.prompt,
            transcriptPath: RowFixture.transcriptPath
        )
    }

    private func rowCell(marker: FileExplorerAgentMarker) -> TerminalFileExplorerRowCellView {
        let item = TerminalFileExplorerOutlineItem(
            node: FileExplorerNode(
                url: URL(fileURLWithPath: "/Users/tester/dev/project/README.md"),
                kind: .file
            )
        )
        let cell = TerminalFileExplorerRowCellView(
            item: item,
            badge: .modified,
            agentMarker: marker,
            chromeTheme: .dark
        )
        cell.frame = NSRect(
            x: 0,
            y: 0,
            width: RowFixture.rowWidthPX,
            height: DesignTokens.Component.fileExplorerRowHeightPX
        )
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    func testAMarkedRowExplainsItselfInTheTooltip() throws {
        let url = URL(fileURLWithPath: "/Users/tester/dev/project/README.md")
        let marker = FileExplorerAgentMarker(touch: touch(for: url), hasRecentChange: true)
        let tooltip = try XCTUnwrap(rowCell(marker: marker).toolTip)
        XCTAssertTrue(tooltip.contains(AgentSessionKind.claudeCode.displayName))
        XCTAssertTrue(tooltip.contains(RowFixture.prompt))
    }

    func testAnUnmarkedRowCarriesNoTooltip() {
        XCTAssertNil(rowCell(marker: .none).toolTip)
    }

    /// The reason the column is reserved rather than inserted on demand: a slot
    /// that appears and disappears would move the file name from row to row,
    /// which is exactly the defect the git column was rebuilt to remove.
    func testTheAgentColumnIsReservedWhetherOrNotItDraws() {
        let url = URL(fileURLWithPath: "/Users/tester/dev/project/README.md")
        let marked = rowCell(
            marker: FileExplorerAgentMarker(touch: touch(for: url), hasRecentChange: true)
        )
        let unmarked = rowCell(marker: .none)
        for cell in [marked, unmarked] {
            let agentSlot = cell.subviews.compactMap { $0 as? TerminalFileExplorerAgentSlotView }.first
            let gitSlot = cell.subviews.compactMap { $0 as? TerminalFileExplorerGitSlotView }.first
            XCTAssertNotNil(agentSlot)
            XCTAssertNotNil(gitSlot)
            XCTAssertEqual(
                agentSlot?.frame.width,
                DesignTokens.Component.fileExplorerAgentSlotSizePX
            )
            // Agent column sits immediately before the git column.
            XCTAssertEqual(agentSlot?.frame.maxX, gitSlot?.frame.minX)
        }
        XCTAssertEqual(
            marked.subviews.compactMap { $0 as? TerminalFileExplorerAgentSlotView }.first?.frame,
            unmarked.subviews.compactMap { $0 as? TerminalFileExplorerAgentSlotView }.first?.frame
        )
    }

    func testTranscriptContextActionIsOfferedOnlyForFilesAnAgentWrote() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-provenance-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("README.md")
        try "content\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let panel = TerminalFileExplorerPanelView(
            agentSessionIndexStore: AgentSessionIndexStore(
                homeDirectory: root,
                scanners: [],
                isIndexingEnabled: false,
                observesSettingsChanges: false
            )
        )
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        panel.update(rootDirectory: root)
        panel.layoutSubtreeIfNeeded()

        let menu = try XCTUnwrap(panel.contextMenuForTesting)
        let transcriptTitle = AppLocalization.string(.revealTranscriptInFinder)
        let transcriptItem = try XCTUnwrap(menu.items.first { $0.title == transcriptTitle })

        panel.selectRowForTesting(0)
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertFalse(transcriptItem.isEnabled)

        panel.setAgentProvenanceForTesting(AgentFileProvenanceIndex(touches: [touch(for: file)]))
        panel.selectRowForTesting(0)
        menu.delegate?.menuNeedsUpdate?(menu)
        XCTAssertTrue(transcriptItem.isEnabled)
        XCTAssertTrue(
            panel.agentMarkerForTesting(
                absolutePath: file.standardizedFileURL.path,
                now: Date()
            ).hasRecentChange
        )
    }
}
