import XCTest

/// `scripts/version.sh` decides what a release is called, so getting it wrong
/// produces a mislabelled DMG or an empty filename. It replaced a checked-in
/// `VERSION` file whose only real job was to be the fallback for an
/// argument-less local run — the tag already decided the version, and keeping
/// the file in sync cost a commit and two pull requests before every release.
final class ReleaseVersionResolutionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Sources the helper and calls it, so the test exercises the shipped shell
    /// rather than a Swift reimplementation of it.
    private func resolveVersion(
        argument: String? = nil,
        workingDirectory: URL? = nil,
        prependingPath: String? = nil
    ) throws -> String {
        let script = repositoryRoot.appendingPathComponent("scripts/version.sh").path
        let call = argument.map { "kurotty_resolve_version \"\($0)\"" } ?? "kurotty_resolve_version"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"\(script)\"; \(call)"]
        process.currentDirectoryURL = workingDirectory ?? repositoryRoot
        if let prependingPath {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = prependingPath + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testAnExplicitArgumentWins() throws {
        XCTAssertEqual(try resolveVersion(argument: "1.2.3-alpha.7"), "1.2.3-alpha.7")
    }

    /// Tags carry a leading `v`; `CFBundleShortVersionString` must not.
    func testALeadingVIsStripped() throws {
        XCTAssertEqual(try resolveVersion(argument: "v1.2.3-alpha.7"), "1.2.3-alpha.7")
        XCTAssertEqual(try resolveVersion(argument: "v0.1.0-alpha.59"), "0.1.0-alpha.59")
    }

    /// Whatever it derives, it is never empty and never keeps the `v`. An empty
    /// version silently produces `kurotty--macos-universal.dmg`.
    func testDerivedVersionIsNeverEmptyAndNeverKeepsTheTagPrefix() throws {
        let derived = try resolveVersion()
        XCTAssertFalse(derived.isEmpty)
        XCTAssertFalse(derived.hasPrefix("v"))
    }

    func testOutsideARepositoryItFallsBackToADevMarker() throws {
        XCTAssertEqual(
            try resolveVersion(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory())),
            "0.0.0-dev"
        )
    }

    /// A git that cannot answer must not yield an empty string.
    func testAFailingGitFallsBackRatherThanResolvingToNothing() throws {
        let stubDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-version-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stubDirectory) }

        let stub = stubDirectory.appendingPathComponent("git")
        try "#!/bin/sh\nexit 127\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        XCTAssertEqual(try resolveVersion(prependingPath: stubDirectory.path), "0.0.0-dev")
    }

    /// The file is gone on purpose; a stray copy would drift and mislead.
    func testTheVersionFileIsNotResurrected() {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent("VERSION").path)
        )
    }
}
