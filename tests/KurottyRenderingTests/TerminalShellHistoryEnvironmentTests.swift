import XCTest
@testable import KurottyApp
@testable import KurottyCore

/// Per-project `HISTFILE` derivation. Every case uses temporary directories;
/// nothing here reads or writes the real `~/.zsh_history`.
final class TerminalShellHistoryEnvironmentTests: XCTestCase {
    private enum Fixture {
        static let zshPath = "/bin/zsh"
        static let versionedBashPath = "/usr/local/bin/bash-5.2"
        static let nixStoreZshPath = "/nix/store/abc123-zsh-5.9/bin/zsh"
        static let fishPath = "/opt/homebrew/bin/fish"
        static let unknownShellPath = "/usr/bin/nu"
        static let userConfiguredHistoryFile = "/Users/tester/.config/zsh/history"
        static let projectDirectory = "/Users/tester/dev/kurotty"
        static let nestedDirectory = "/Users/tester/dev/kurotty/Sources/KurottyApp"
        static let gitRoot = "/Users/tester/dev/kurotty"
        static let applicationSupport = "/Users/tester/Library/Application Support"
    }

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-shell-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    // MARK: - Shell kind prefix matching

    func testShellKindMatchesPlainBinaryNames() {
        XCTAssertEqual(
            TerminalShellHistoryEnvironment.shellKind(forBinaryPath: Fixture.zshPath),
            .zsh
        )
        XCTAssertEqual(
            TerminalShellHistoryEnvironment.shellKind(forBinaryPath: "/bin/bash"),
            .bash
        )
    }

    func testShellKindMatchesVersionedBinaryNamesByPrefix() {
        XCTAssertEqual(
            TerminalShellHistoryEnvironment.shellKind(forBinaryPath: Fixture.versionedBashPath),
            .bash
        )
    }

    func testShellKindMatchesNixStorePaths() {
        XCTAssertEqual(
            TerminalShellHistoryEnvironment.shellKind(forBinaryPath: Fixture.nixStoreZshPath),
            .zsh
        )
    }

    func testShellKindRecognizesFishAndUnknownShells() {
        XCTAssertEqual(
            TerminalShellHistoryEnvironment.shellKind(forBinaryPath: Fixture.fishPath),
            .fish
        )
        XCTAssertEqual(
            TerminalShellHistoryEnvironment.shellKind(forBinaryPath: Fixture.unknownShellPath),
            .unknown
        )
    }

    func testHistoryFileNameIsNilForShellsThatDoNotUseHistFile() {
        XCTAssertEqual(TerminalShellHistoryEnvironment.historyFileName(for: .zsh), "zsh_history")
        XCTAssertEqual(TerminalShellHistoryEnvironment.historyFileName(for: .bash), "bash_history")
        XCTAssertNil(TerminalShellHistoryEnvironment.historyFileName(for: .fish))
        XCTAssertNil(TerminalShellHistoryEnvironment.historyFileName(for: .unknown))
    }

    // MARK: - Project identity

    func testProjectIdentityPrefersTheGitRoot() {
        let identity = TerminalShellHistoryEnvironment.projectIdentity(
            forWorkingDirectory: Fixture.nestedDirectory,
            gitRootLookup: { _ in Fixture.gitRoot }
        )

        XCTAssertEqual(identity, Fixture.gitRoot)
    }

    func testProjectIdentityFallsBackToTheDirectoryItself() {
        let identity = TerminalShellHistoryEnvironment.projectIdentity(
            forWorkingDirectory: Fixture.nestedDirectory,
            gitRootLookup: { _ in nil }
        )

        XCTAssertEqual(identity, Fixture.nestedDirectory)
    }

    func testProjectIdentityIsNilWithoutAWorkingDirectory() {
        XCTAssertNil(TerminalShellHistoryEnvironment.projectIdentity(
            forWorkingDirectory: nil,
            gitRootLookup: { _ in nil }
        ))
    }

    func testGitRootLookupWalksUpwardToTheRepositoryRoot() throws {
        let root = temporaryDirectory.appendingPathComponent("repo")
        let nested = root.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            TerminalShellHistoryEnvironment.defaultGitRootLookup(nested.path),
            root.path
        )
    }

    func testGitRootLookupReturnsNilOutsideARepository() throws {
        let plain = temporaryDirectory.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        // The temporary directory tree itself must not be inside a repository.
        XCTAssertNil(TerminalShellHistoryEnvironment.defaultGitRootLookup(plain.path))
    }

    // MARK: - Hashing and path derivation

    func testProjectHashIsStableAndTruncated() {
        let first = TerminalShellHistoryEnvironment.projectHash(Fixture.projectDirectory)
        let second = TerminalShellHistoryEnvironment.projectHash(Fixture.projectDirectory)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.count,
            TerminalShellHistoryEnvironment.projectHashLengthCharacters
        )
        XCTAssertNotEqual(
            first,
            TerminalShellHistoryEnvironment.projectHash(Fixture.nestedDirectory)
        )
    }

    func testResolvedHistoryFilePathUsesTheProjectHashedDirectory() {
        let expectedHash = TerminalShellHistoryEnvironment.projectHash(Fixture.gitRoot)

        let path = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: Fixture.nestedDirectory,
            shellPath: Fixture.zshPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in Fixture.gitRoot }
        )

        XCTAssertEqual(
            path,
            "\(Fixture.applicationSupport)/Kurotty/shell-history/\(expectedHash)/zsh_history"
        )
    }

    func testResolvedHistoryFilePathUsesTheBashHistoryFileName() {
        let path = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: Fixture.projectDirectory,
            shellPath: Fixture.versionedBashPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in nil }
        )

        XCTAssertEqual(path?.hasSuffix("/bash_history"), true)
    }

    func testTwoDirectoriesInTheSameRepositoryShareOneHistoryFile() {
        let makePath: (String) -> String? = { directory in
            TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
                workingDirectory: directory,
                shellPath: Fixture.zshPath,
                inheritedHistoryFile: nil,
                applicationSupportDirectory: Fixture.applicationSupport,
                gitRootLookup: { _ in Fixture.gitRoot }
            )
        }

        XCTAssertEqual(makePath(Fixture.projectDirectory), makePath(Fixture.nestedDirectory))
    }

    func testDifferentProjectsGetDifferentHistoryFiles() {
        let first = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: Fixture.projectDirectory,
            shellPath: Fixture.zshPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in nil }
        )
        let second = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: "/Users/tester/dev/other",
            shellPath: Fixture.zshPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in nil }
        )

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Check-before-set

    func testUserConfiguredHistoryFileIsNeverOverridden() {
        let path = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: Fixture.projectDirectory,
            shellPath: Fixture.zshPath,
            inheritedHistoryFile: Fixture.userConfiguredHistoryFile,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in nil }
        )

        XCTAssertNil(path)
        XCTAssertFalse(TerminalShellHistoryEnvironment.shouldUseGlobalFallback(
            inheritedHistoryFile: Fixture.userConfiguredHistoryFile
        ))
    }

    func testGlobalFallbackIsAllowedWhenNothingIsInherited() {
        XCTAssertTrue(
            TerminalShellHistoryEnvironment.shouldUseGlobalFallback(inheritedHistoryFile: nil)
        )
        XCTAssertTrue(
            TerminalShellHistoryEnvironment.shouldUseGlobalFallback(inheritedHistoryFile: "")
        )
    }

    func testUnknownWorkingDirectoryFallsBackToTodaysBehavior() {
        let path = TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: nil,
            shellPath: Fixture.zshPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in nil }
        )

        XCTAssertNil(path)
        XCTAssertTrue(
            TerminalShellHistoryEnvironment.shouldUseGlobalFallback(inheritedHistoryFile: nil)
        )
    }

    func testShellsWithoutHistFileSupportAreLeftAlone() {
        XCTAssertNil(TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: Fixture.projectDirectory,
            shellPath: Fixture.fishPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            gitRootLookup: { _ in nil }
        ))
    }

    func testDisablingTheFeatureFallsBackToTodaysBehavior() {
        XCTAssertNil(TerminalShellHistoryEnvironment.resolvedHistoryFilePath(
            workingDirectory: Fixture.projectDirectory,
            shellPath: Fixture.zshPath,
            inheritedHistoryFile: nil,
            applicationSupportDirectory: Fixture.applicationSupport,
            isEnabled: false,
            gitRootLookup: { _ in nil }
        ))
    }

    // MARK: - Source shape

    func testShellSessionNoLongerForcesTheGlobalHistoryFileUnconditionally() throws {
        let source = try shellSessionSource()

        XCTAssertFalse(
            source.contains(#"setenv("HISTFILE", "\(homeDirectory)/.zsh_history", 1)"#),
            "HISTFILE must go through TerminalShellHistoryEnvironment, not a forced global path"
        )
        XCTAssertTrue(source.contains("perProjectHistoryFilePath"))
        XCTAssertTrue(source.contains("mayExportGlobalHistoryFallback"))
    }

    private func shellSessionSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/KurottyApp/ShellSession.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
