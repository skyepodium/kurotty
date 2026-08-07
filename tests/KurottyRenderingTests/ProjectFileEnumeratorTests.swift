import XCTest
@testable import KurottyApp

/// Enumeration for the project file palette: ripgrep output parsing, the
/// fallback walk, and — the point of the whole design — what happens when
/// ripgrep is not installed.
final class ProjectFileEnumeratorTests: XCTestCase {
    // MARK: - Ripgrep output

    func testEachOutputLineIsOnePathTakenVerbatim() {
        let parsed = ProjectFileRipgrepOutput.relativePaths(
            from: "src/a.swift\nsrc/my file.swift\n.hidden/b.txt\n",
            limit: 50
        )
        XCTAssertEqual(parsed.paths, ["src/a.swift", "src/my file.swift", ".hidden/b.txt"])
        XCTAssertFalse(parsed.isTruncated)
    }

    func testBlankLinesAreDroppedRatherThanBecomingEmptyPaths() {
        let parsed = ProjectFileRipgrepOutput.relativePaths(from: "\n\na.swift\n\n", limit: 50)
        XCTAssertEqual(parsed.paths, ["a.swift"])
    }

    func testOutputBeyondTheCapIsTruncatedAndSaysSo() {
        let parsed = ProjectFileRipgrepOutput.relativePaths(from: "a\nb\nc\n", limit: 2)
        XCTAssertEqual(parsed.paths, ["a", "b"])
        XCTAssertTrue(parsed.isTruncated)
    }

    func testEmptyOutputIsNotTruncated() {
        let parsed = ProjectFileRipgrepOutput.relativePaths(from: "", limit: 50)
        XCTAssertEqual(parsed.paths, [])
        XCTAssertFalse(parsed.isTruncated)
    }

    // MARK: - Fallback walk

    /// A tree the walk can be driven over without touching disk. Depth is
    /// encoded in the path so the breadth-first order can be asserted.
    private func stubProvider(_ tree: [String: [FileExplorerNode]]) -> (URL) -> [FileExplorerNode] {
        { url in tree[url.path] ?? [] }
    }

    private func directory(_ path: String) -> FileExplorerNode {
        FileExplorerNode(url: URL(fileURLWithPath: path, isDirectory: true), kind: .directory)
    }

    private func file(_ path: String) -> FileExplorerNode {
        FileExplorerNode(url: URL(fileURLWithPath: path), kind: .file)
    }

    func testTheWalkReportsPathsRelativeToTheScannedRoot() {
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        let listing = ProjectFileDirectoryWalk.listing(
            rootDirectory: root,
            childProvider: stubProvider([
                "/root": [directory("/root/src"), file("/root/Package.swift")],
                "/root/src": [file("/root/src/main.swift")],
            ])
        )
        XCTAssertEqual(listing.relativePaths.sorted(), ["Package.swift", "src/main.swift"])
        XCTAssertEqual(listing.source, .directoryWalk)
        XCTAssertFalse(listing.isTruncated)
    }

    func testTheWalkSpendsItsBudgetOnShallowFilesBeforeDeepOnes() {
        // The whole reason this is breadth-first. Depth-first under the same
        // budget disappears into the first heavy subtree — which in a real
        // checkout is `.build` or `node_modules` — and never reaches the
        // project's own sources.
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        var tree: [String: [FileExplorerNode]] = [
            "/root": [directory("/root/heavy"), file("/root/wanted.swift")],
        ]
        // A subtree far larger than the budget, listed first.
        tree["/root/heavy"] = (0..<50).map { file("/root/heavy/junk\($0).swift") }

        let listing = ProjectFileDirectoryWalk.listing(
            rootDirectory: root,
            limit: 5,
            maximumVisitedEntryCount: 5,
            childProvider: stubProvider(tree)
        )
        XCTAssertTrue(listing.relativePaths.contains("wanted.swift"))
        XCTAssertTrue(listing.isTruncated)
    }

    func testTheWalkStopsAtTheFileCapAndReportsTruncation() {
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        let listing = ProjectFileDirectoryWalk.listing(
            rootDirectory: root,
            limit: 2,
            childProvider: stubProvider([
                "/root": (0..<10).map { file("/root/f\($0).swift") },
            ])
        )
        XCTAssertEqual(listing.relativePaths.count, 2)
        XCTAssertTrue(listing.isTruncated)
    }

    func testTheWalkStopsAtTheVisitedEntryCapEvenWhenNoFilesWereFound() {
        // The file cap alone cannot bound a tree of nothing but directories.
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        var tree: [String: [FileExplorerNode]] = [:]
        for depth in 0..<20 {
            let path = "/root" + String(repeating: "/d", count: depth)
            tree[path] = [directory(path + "/d")]
        }
        let listing = ProjectFileDirectoryWalk.listing(
            rootDirectory: root,
            limit: 100,
            maximumVisitedEntryCount: 5,
            childProvider: stubProvider(tree)
        )
        XCTAssertEqual(listing.relativePaths, [])
        XCTAssertTrue(listing.isTruncated)
    }

    func testTheWalkNeverDescendsIntoAGitDirectory() {
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        let listing = ProjectFileDirectoryWalk.listing(
            rootDirectory: root,
            childProvider: stubProvider([
                "/root": [directory("/root/.git"), file("/root/a.swift")],
                "/root/.git": [file("/root/.git/config")],
            ])
        )
        XCTAssertEqual(listing.relativePaths, ["a.swift"])
    }

    func testAnEmptyRootProducesAnEmptyCompleteListing() {
        let listing = ProjectFileDirectoryWalk.listing(
            rootDirectory: URL(fileURLWithPath: "/root", isDirectory: true),
            childProvider: stubProvider([:])
        )
        XCTAssertEqual(listing.relativePaths, [])
        XCTAssertFalse(listing.isTruncated)
    }

    // MARK: - Absent binary

    func testAnUninstallableRipgrepYieldsNoRipgrepListing() throws {
        // Stands in for a machine without ripgrep: a name `env` cannot resolve
        // is the same failure an uninstalled binary produces.
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = ProjectFileEnumerationRunner.ripgrepListing(
            rootDirectory: root,
            limit: 50,
            executableName: "kurotty-not-a-real-binary"
        )
        XCTAssertNil(listing)
    }

    func testAMissingRipgrepFallsBackToTheWalkRatherThanFailing() throws {
        // The contract that makes ripgrep optional. A missing binary must never
        // be a broken feature: the palette still gets its files, and the
        // listing says which enumerator answered so the footer can too.
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = ProjectFileEnumerationRunner.listing(
            rootDirectory: root,
            executableName: "kurotty-not-a-real-binary"
        )
        XCTAssertEqual(listing.source, .directoryWalk)
        XCTAssertTrue(listing.relativePaths.contains("src/main.swift"))
    }

    func testTheFallbackStillFindsFilesGitWouldHaveIgnored() throws {
        // The honest limit of the degraded path, pinned so it cannot be
        // mistaken for gitignore support: the walk reads no ignore rules, so a
        // build directory is in the results. That is exactly why the footer
        // names the enumerator rather than staying silent.
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let buildDirectory = root.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: buildDirectory.appendingPathComponent("artifact.o"))
        try Data("*.o\n.build/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))

        let listing = ProjectFileEnumerationRunner.listing(
            rootDirectory: root,
            executableName: "kurotty-not-a-real-binary"
        )
        XCTAssertTrue(listing.relativePaths.contains(".build/artifact.o"))
    }

    func testTheEnumeratorAlwaysReturnsAListingWhicheverSourceAnswered() throws {
        // Whether ripgrep is installed on the machine running the suite is not
        // something a test may assume, so this asserts the invariant that holds
        // either way: a real project always comes back with its files, and the
        // listing names which enumerator produced them.
        let root = try makeTemporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = ProjectFileEnumerationRunner.listing(rootDirectory: root)
        XCTAssertTrue(listing.relativePaths.contains("src/main.swift"))
        XCTAssertTrue([.ripgrep, .directoryWalk].contains(listing.source))
    }

    func testAnUnreadableRootDegradesToAnEmptyListingRatherThanCrashing() {
        let listing = ProjectFileEnumerationRunner.listing(
            rootDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)", isDirectory: true)
        )
        XCTAssertEqual(listing.relativePaths, [])
    }

    private func makeTemporaryProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-project-files-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("// main".utf8).write(to: sourceDirectory.appendingPathComponent("main.swift"))
        return root
    }
}
