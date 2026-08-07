import XCTest
@testable import KurottyApp

/// Ranking rules for the project file palette.
///
/// Every test here asserts an ordering or a rejection, never a score: the
/// numbers in `ProjectFileRank` are free to move as long as the file a person
/// meant still comes back first.
final class ProjectFileMatcherTests: XCTestCase {
    private func topPath(_ paths: [String], _ query: String) -> String? {
        ProjectFileMatcher.matches(
            index: ProjectFileIndex(relativePaths: paths),
            query: query,
            limit: 50
        ).first?.relativePath
    }

    private func orderedPaths(_ paths: [String], _ query: String) -> [String] {
        ProjectFileMatcher.matches(
            index: ProjectFileIndex(relativePaths: paths),
            query: query,
            limit: 50
        ).map(\.relativePath)
    }

    // MARK: - Matching

    func testCamelCaseInitialsFindTheFileTheyAbbreviate() {
        // The reason boundaries are computed before case folding: by the time
        // the path is lowercased the humps that make `tsv` meaningful are gone.
        let paths = [
            "Sources/KurottyApp/TerminalScrollWheelAccumulator.swift",
            "Sources/KurottyApp/TerminalSurfaceView.swift",
        ]
        XCTAssertEqual(topPath(paths, "tsv"), "Sources/KurottyApp/TerminalSurfaceView.swift")
    }

    func testAQueryThatIsNotASubsequenceMatchesNothing() {
        XCTAssertEqual(orderedPaths(["Sources/App/Main.swift"], "zzz"), [])
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        XCTAssertEqual(orderedPaths(["src/Café.swift"], "CAFE"), ["src/Café.swift"])
    }

    func testInteriorWhitespaceIsIgnoredRatherThanTreatedAsASeparator() {
        // A path never contains a space between the words a user types, so
        // "terminal surface" has to mean the same as "terminalsurface".
        let paths = ["Sources/TerminalSurfaceView.swift"]
        XCTAssertEqual(orderedPaths(paths, "terminal surface"), paths)
    }

    func testAWhitespaceOnlyQueryReturnsTheHeadOfTheListingUnsorted() {
        // Enumeration order carries information — ripgrep walks the tree in
        // directory order — so an empty query must not re-sort it.
        let paths = ["z.swift", "a.swift", "m.swift"]
        XCTAssertEqual(orderedPaths(paths, "   "), paths)
    }

    func testTheEmptyQueryIsDistinctFromNoMatches() {
        XCTAssertNil(ProjectFileMatcher.normalizedQuery("  \n "))
        XCTAssertNotNil(ProjectFileMatcher.normalizedQuery("a"))
    }

    // MARK: - Ranking

    func testAFileNameMatchOutranksADirectoryOnlyMatchInAShorterPath() {
        // `readme` is in the directory of the first path and in the name of the
        // second. The name wins even though the other path is shorter.
        let paths = ["readme/x.txt", "docs/readme.md"]
        XCTAssertEqual(topPath(paths, "readme"), "docs/readme.md")
    }

    func testAContiguousMatchOutranksAScatteredOneInTheSameName() {
        let paths = ["src/abcdefg.swift", "src/abc.swift"]
        XCTAssertEqual(topPath(paths, "abc"), "src/abc.swift")
    }

    func testAShallowerFileWinsWhenEverythingElseTies() {
        let paths = ["a/b/c/main.swift", "a/main.swift"]
        XCTAssertEqual(topPath(paths, "main"), "a/main.swift")
    }

    func testASlashInTheQueryForcesWholePathMatchingRatherThanNameMatching() {
        // Typing a separator is how a user says "I mean this directory". A
        // query with one must not be answered by a file whose bare name
        // happens to contain the letters.
        let paths = ["helpers/notmodels.swift", "models/user.swift"]
        XCTAssertEqual(orderedPaths(paths, "models/user"), ["models/user.swift"])
    }

    func testOrderingIsDeterministicForOtherwiseIdenticalPaths() {
        // Two paths equal on every rule must not come back in enumeration
        // order, or the same query gives two different answers on two scans.
        let forward = orderedPaths(["b/x.swift", "a/x.swift"], "x")
        let reversed = orderedPaths(["a/x.swift", "b/x.swift"], "x")
        XCTAssertEqual(forward, reversed)
    }

    func testTheLimitCapsResultsWithoutChangingWhichOnesWin() {
        let paths = ["a/main.swift", "b/c/main.swift", "d/e/f/main.swift"]
        let capped = ProjectFileMatcher.matches(
            index: ProjectFileIndex(relativePaths: paths),
            query: "main",
            limit: 2
        )
        XCTAssertEqual(capped.map(\.relativePath), ["a/main.swift", "b/c/main.swift"])
    }

    func testAZeroLimitReturnsNothingRatherThanEverything() {
        let matches = ProjectFileMatcher.matches(
            index: ProjectFileIndex(relativePaths: ["a.swift"]),
            query: "a",
            limit: 0
        )
        XCTAssertEqual(matches.count, 0)
    }

    // MARK: - Index preparation

    func testAPathWithNoDirectoryPartHasZeroDepthAndMatchesOnItsWholeName() {
        let entry = ProjectFileIndexEntry(relativePath: "Package.swift")
        XCTAssertEqual(entry.depthCOUNT, 0)
        XCTAssertEqual(entry.filenameStartOffset, 0)
    }

    func testTheFilenameOffsetPointsPastTheLastSeparator() {
        let entry = ProjectFileIndexEntry(relativePath: "a/bb/c.swift")
        XCTAssertEqual(entry.depthCOUNT, 2)
        XCTAssertEqual(String(entry.searchCharacters[entry.filenameStartOffset...]), "c.swift")
    }

    func testBoundariesCoverSeparatorsJoinersAndCamelHumps() {
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "a", previous: nil))
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "a", previous: "/"))
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "a", previous: "."))
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "a", previous: "-"))
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "a", previous: "_"))
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "V", previous: "e"))
        XCTAssertTrue(ProjectFileMatcher.isBoundary(character: "D", previous: "8"))
        XCTAssertFalse(ProjectFileMatcher.isBoundary(character: "b", previous: "a"))
    }
}
