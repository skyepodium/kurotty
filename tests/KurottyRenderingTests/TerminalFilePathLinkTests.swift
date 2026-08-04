import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// Coverage for `path:line:col` terminal link detection: pure candidate
/// extraction, resolution, ranking, wrapped-line joining, and the bounded
/// path-exists cache.
final class TerminalFilePathLinkTests: XCTestCase {
    private enum Fixture {
        static let workingDirectory = "/Users/tester/dev/kurotty"
        static let homeDirectory = "/Users/tester"
        static let cacheProbeCount = 600
    }

    // MARK: - Candidate extraction

    func testRelativePathWithSeparatorIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "see src/foo.swift for details")

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.pathText, "src/foo.swift")
        XCTAssertNil(candidates.first?.line)
        XCTAssertEqual(candidates.first?.startIndex, 4)
        XCTAssertEqual(candidates.first?.endIndex, 4 + "src/foo.swift".count)
    }

    func testRelativePathWithLineNumberIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "src/foo.swift:42")

        XCTAssertEqual(candidates.first?.pathText, "src/foo.swift")
        XCTAssertEqual(candidates.first?.line, 42)
        XCTAssertNil(candidates.first?.column)
        XCTAssertEqual(candidates.first?.endIndex, "src/foo.swift:42".count)
    }

    func testDotSlashPathWithLineAndColumnIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "at ./a/b.ts:12:5")

        XCTAssertEqual(candidates.first?.pathText, "./a/b.ts")
        XCTAssertEqual(candidates.first?.line, 12)
        XCTAssertEqual(candidates.first?.column, 5)
    }

    func testAbsolutePathWithoutLineIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "wrote /abs/path.py now")

        XCTAssertEqual(candidates.first?.pathText, "/abs/path.py")
        XCTAssertNil(candidates.first?.line)
    }

    func testTildePathIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "~/notes/todo.md:7")

        XCTAssertEqual(candidates.first?.pathText, "~/notes/todo.md")
        XCTAssertEqual(candidates.first?.line, 7)
    }

    func testParenthesisedLineNumberIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: #"a\b.rs(31)"#)

        XCTAssertEqual(candidates.first?.pathText, #"a\b.rs"#)
        XCTAssertEqual(candidates.first?.line, 31)
        XCTAssertEqual(candidates.first?.endIndex, #"a\b.rs(31)"#.count)
    }

    func testTrailingColonAfterLineNumberIsNotConsumed() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "foo.swift:42: warning: bad")

        XCTAssertEqual(candidates.first?.pathText, "foo.swift")
        XCTAssertEqual(candidates.first?.line, 42)
        XCTAssertEqual(candidates.first?.endIndex, "foo.swift:42".count)
    }

    func testParenthesisWrappedPathDropsTheClosingParenthesis() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "(src/a.ts:3)")

        XCTAssertEqual(candidates.first?.pathText, "src/a.ts")
        XCTAssertEqual(candidates.first?.line, 3)
        XCTAssertEqual(candidates.first?.startIndex, 1)
    }

    func testParenthesisWrappedPathWithoutLineDropsTheClosingParenthesis() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "(src/a.ts)")

        XCTAssertEqual(candidates.first?.pathText, "src/a.ts")
        XCTAssertEqual(candidates.first?.endIndex, 1 + "src/a.ts".count)
    }

    func testBalancedParenthesesInsideRouteFilePathAreKept() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "app/(shop)/page.tsx:9")

        XCTAssertEqual(candidates.first?.pathText, "app/(shop)/page.tsx")
        XCTAssertEqual(candidates.first?.line, 9)
    }

    func testTrailingSentencePunctuationIsTrimmed() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "edited src/a.ts.")

        XCTAssertEqual(candidates.first?.pathText, "src/a.ts")
    }

    func testBareFilenameWithKnownExtensionIsExtracted() {
        let candidates = TerminalFilePathLinkDetector.candidates(in: "compiling main.swift")

        XCTAssertEqual(candidates.first?.pathText, "main.swift")
    }

    // MARK: - Non-paths

    func testTimestampIsNotAPathCandidate() {
        XCTAssertTrue(TerminalFilePathLinkDetector.candidates(in: "started at 10:30").isEmpty)
    }

    func testTimestampWithSecondsIsNotAPathCandidate() {
        XCTAssertTrue(TerminalFilePathLinkDetector.candidates(in: "10:30:15 done").isEmpty)
    }

    func testHTTPURLWithPortIsNotAPathCandidate() {
        XCTAssertTrue(TerminalFilePathLinkDetector.candidates(in: "open http://x/y:80").isEmpty)
    }

    func testHTTPSURLIsNotAPathCandidate() {
        XCTAssertTrue(
            TerminalFilePathLinkDetector.candidates(in: "see https://example.com/a/b.ts:12").isEmpty
        )
    }

    func testVersionNumberIsNotAPathCandidate() {
        XCTAssertTrue(TerminalFilePathLinkDetector.candidates(in: "release v1.2 shipped").isEmpty)
    }

    func testBareSlashIsNotAPathCandidate() {
        XCTAssertTrue(TerminalFilePathLinkDetector.candidates(in: "yes / no").isEmpty)
    }

    func testTrailingSeparatorDirectoryIsNotAPathCandidate() {
        XCTAssertTrue(TerminalFilePathLinkDetector.candidates(in: "cd src/lib/").isEmpty)
    }

    // MARK: - Resolution

    func testRelativeCandidateResolvesAgainstWorkingDirectoryThenHome() {
        let candidate = TerminalFilePathLinkDetector.candidates(in: "src/foo.swift:1")[0]

        let paths = TerminalFilePathLinkDetector.resolutionPaths(
            for: candidate,
            workingDirectory: Fixture.workingDirectory,
            homeDirectory: Fixture.homeDirectory
        )

        XCTAssertEqual(paths, [
            Fixture.workingDirectory + "/src/foo.swift",
            Fixture.homeDirectory + "/src/foo.swift",
        ])
    }

    func testTildeCandidateResolvesAgainstHomeOnly() {
        let candidate = TerminalFilePathLinkDetector.candidates(in: "~/notes/todo.md")[0]

        XCTAssertEqual(
            TerminalFilePathLinkDetector.resolutionPaths(
                for: candidate,
                workingDirectory: Fixture.workingDirectory,
                homeDirectory: Fixture.homeDirectory
            ),
            [Fixture.homeDirectory + "/notes/todo.md"]
        )
    }

    func testBackslashCandidateIsNormalizedToForwardSlashes() {
        let candidate = TerminalFilePathLinkDetector.candidates(in: #"a\b.rs(31)"#)[0]

        XCTAssertEqual(
            TerminalFilePathLinkDetector.resolutionPaths(
                for: candidate,
                workingDirectory: Fixture.workingDirectory,
                homeDirectory: Fixture.homeDirectory
            ).first,
            Fixture.workingDirectory + "/a/b.rs"
        )
    }

    // MARK: - Ranking

    func testRankingPrefersAnExistingPathOverAnUnprobedOne() {
        let existing = resolution(pathText: "a.ts", exists: true)
        let unprobed = resolution(pathText: "some/longer/path.ts", exists: nil)

        XCTAssertEqual(
            TerminalFilePathLinkDetector.bestMatch(among: [unprobed, existing])?.absolutePath,
            existing.absolutePath
        )
    }

    func testRankingPrefersTheLongestExistingPath() {
        let short = resolution(pathText: "b.ts", exists: true)
        let long = resolution(pathText: "src/nested/b.ts", exists: true)

        XCTAssertEqual(
            TerminalFilePathLinkDetector.bestMatch(among: [short, long])?.absolutePath,
            long.absolutePath
        )
    }

    func testRankingNeverPicksAPathKnownToBeMissing() {
        let missing = resolution(pathText: "gone.ts", exists: false)

        XCTAssertNil(TerminalFilePathLinkDetector.bestMatch(among: [missing]))
    }

    func testOverlappingConfirmedCandidatesKeepOnlyTheLongest() {
        let short = resolution(pathText: "b.ts", exists: true, startIndex: 11, endIndex: 15)
        let long = resolution(pathText: "src/nested/b.ts", exists: true, startIndex: 0, endIndex: 15)

        let accepted = TerminalFilePathLinkDetector.acceptedNonOverlapping([short, long])

        XCTAssertEqual(accepted.map(\.candidate.pathText), ["src/nested/b.ts"])
    }

    func testNonOverlappingConfirmedCandidatesAreBothKept() {
        let first = resolution(pathText: "a.ts", exists: true, startIndex: 0, endIndex: 4)
        let second = resolution(pathText: "b.ts", exists: true, startIndex: 5, endIndex: 9)

        XCTAssertEqual(
            TerminalFilePathLinkDetector.acceptedNonOverlapping([second, first])
                .map(\.candidate.startIndex),
            [0, 5]
        )
    }

    // MARK: - Wrapped-line joining

    func testFileLinkSpanningASoftWrapIsDetectedOnBothRows() {
        let firstPart = "src/deeply/nested/"
        let secondPart = "file.swift:12"
        let absolutePath = Fixture.workingDirectory + "/src/deeply/nested/file.swift"
        var firstRow = cells(firstPart)
        firstRow[firstRow.count - 1].wrapsToNextRow = true

        let ranges = TerminalLinkRange.findAll(
            in: [firstRow, cells(secondPart)],
            startingRow: 0,
            fileLinkContext: context(existingPaths: [absolutePath])
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.map(\.row), [0, 1])
        XCTAssertEqual(
            ranges.first?.fileTarget,
            TerminalFileLinkTarget(absolutePath: absolutePath, line: 12, column: nil)
        )
        XCTAssertEqual(ranges.last?.endColumn, secondPart.count)
    }

    func testUnprobedFilePathIsNotLinkedButRequestsAProbe() {
        var probed: [String] = []
        let ranges = TerminalLinkRange.findAll(
            in: [cells("src/foo.swift:3")],
            startingRow: 0,
            fileLinkContext: context(existingPaths: [], onProbe: { probed.append($0) })
        )

        XCTAssertTrue(ranges.isEmpty)
        XCTAssertEqual(probed.first, Fixture.workingDirectory + "/src/foo.swift")
    }

    func testExistingHTTPLinkDetectionIsUnchangedWhenFileContextIsPresent() {
        let ranges = TerminalLinkRange.findAll(
            in: [cells("Open https://x.ai/grok).")],
            startingRow: 3,
            fileLinkContext: context(existingPaths: [])
        )

        XCTAssertEqual(ranges, [
            TerminalLinkRange(row: 3, startColumn: 5, endColumn: 22, urlString: "https://x.ai/grok"),
        ])
        XCTAssertNil(ranges.first?.fileTarget)
    }

    // MARK: - Cache

    func testCacheReturnsNilForUnprobedPaths() {
        XCTAssertNil(TerminalPathExistsCache().exists("/tmp/unprobed"))
    }

    func testCacheEvictsLeastRecentlyUsedEntriesAtCapacity() {
        let cache = TerminalPathExistsCache(capacity: 3)
        cache.record(path: "/a", exists: true)
        cache.record(path: "/b", exists: true)
        cache.record(path: "/c", exists: true)
        _ = cache.exists("/a")

        cache.record(path: "/d", exists: true)

        XCTAssertEqual(cache.entryCount, 3)
        XCTAssertNil(cache.peek("/b"))
        XCTAssertEqual(cache.peek("/a"), true)
        XCTAssertEqual(cache.peek("/d"), true)
    }

    func testCacheStaysBoundedByItsDefaultCapacity() {
        let cache = TerminalPathExistsCache()
        for index in 0..<Fixture.cacheProbeCount {
            cache.record(path: "/tmp/path-\(index)", exists: index.isMultiple(of: 2))
        }

        XCTAssertEqual(cache.entryCount, TerminalPathExistsCache.maximumEntryCount)
        XCTAssertEqual(cache.pathsByRecency.count, TerminalPathExistsCache.maximumEntryCount)
    }

    func testRecordingAnExistingPathUpdatesWithoutGrowing() {
        let cache = TerminalPathExistsCache(capacity: 2)
        cache.record(path: "/a", exists: false)
        cache.record(path: "/a", exists: true)

        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.peek("/a"), true)
    }

    // MARK: - Editor line targeting

    func testEditorLineRangeSelectsTheRequestedLine() {
        let text = "alpha\nbeta\ngamma"

        let range = TerminalCodeEditorLineRange.characterRange(forLine: 2, in: text)

        XCTAssertEqual(range, NSRange(location: 6, length: 4))
    }

    func testEditorLineRangeRejectsOutOfRangeLines() {
        XCTAssertNil(TerminalCodeEditorLineRange.characterRange(forLine: 9, in: "alpha\nbeta"))
        XCTAssertNil(TerminalCodeEditorLineRange.characterRange(forLine: 0, in: "alpha"))
    }

    func testEditorCaretRangeAppliesTheColumnOffset() {
        let range = TerminalCodeEditorLineRange.caretRange(forLine: 2, column: 3, in: "alpha\nbeta")

        XCTAssertEqual(range, NSRange(location: 8, length: 0))
    }

    func testEditorCaretRangeClampsAnOversizedColumn() {
        let range = TerminalCodeEditorLineRange.caretRange(forLine: 1, column: 99, in: "alpha\nbeta")

        XCTAssertEqual(range, NSRange(location: 5, length: 0))
    }

    // MARK: - Helpers

    private func cells(_ text: String) -> [TerminalScreenCell] {
        text.map { TerminalScreenCell(character: $0) }
    }

    private func context(
        existingPaths: Set<String>,
        onProbe: @escaping (String) -> Void = { _ in }
    ) -> TerminalFileLinkContext {
        TerminalFileLinkContext(
            workingDirectory: Fixture.workingDirectory,
            homeDirectory: Fixture.homeDirectory,
            cachedExists: { existingPaths.contains($0) ? true : nil },
            requestExistsProbe: onProbe
        )
    }

    private func resolution(
        pathText: String,
        exists: Bool?,
        startIndex: Int = 0,
        endIndex: Int? = nil
    ) -> TerminalFilePathResolution {
        let candidate = TerminalFilePathCandidate(
            pathText: pathText,
            line: nil,
            column: nil,
            startIndex: startIndex,
            endIndex: endIndex ?? (startIndex + pathText.count)
        )
        return TerminalFilePathResolution(
            candidate: candidate,
            absolutePath: Fixture.workingDirectory + "/" + pathText,
            exists: exists
        )
    }
}
