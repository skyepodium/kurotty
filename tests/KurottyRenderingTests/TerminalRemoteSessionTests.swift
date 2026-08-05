import AppKit
import XCTest
@testable import KurottyApp

/// Coverage for SSH / remote-host sessions: OSC 7 host classification, command
/// history grouping and persistence migration, and the file explorer's
/// local-only short circuit.
///
/// Kurotty browses local files only. The contract under test is that a remote
/// working directory is recognized as remote and reported honestly, never
/// silently treated as a local path.
final class TerminalRemoteSessionTests: XCTestCase {
    private enum Fixture {
        static let localHostName = "Skye-MacBook.local"
        static let remoteHost = "build-box.example.com"
        static let remoteUserHost = "deploy@build-box.example.com"
        static let sharedPath = "/srv/app"
        static let localHome = "/Users/tester"
        static let command = "systemctl restart app"
    }

    // MARK: - Classification

    func testMissingLoopbackAndLocalNameHostsAreLocal() {
        for host in [nil, "", "localhost", "LocalHost", "127.0.0.1", "::1", "[::1]",
                     "skye-macbook", "Skye-MacBook.local"] as [String?] {
            XCTAssertTrue(
                TerminalHostIdentity.isLocal(host: host, localHostName: Fixture.localHostName),
                "\(String(describing: host)) must classify as local"
            )
        }
    }

    func testOtherHostsAreRemote() {
        for host in ["build-box", Fixture.remoteHost, "10.0.0.4", "skye-macbook-2"] {
            XCTAssertFalse(
                TerminalHostIdentity.isLocal(host: host, localHostName: Fixture.localHostName),
                "\(host) must classify as remote"
            )
        }
    }

    /// With no readable local name, an explicit host cannot be proven local,
    /// so it stays remote rather than being guessed into a local path.
    func testUnknownLocalHostNameKeepsNamedHostsRemoteWithoutBlocking() {
        XCTAssertTrue(TerminalHostIdentity.isLocal(host: nil, localHostName: ""))
        XCTAssertTrue(TerminalHostIdentity.isLocal(host: "localhost", localHostName: ""))
        XCTAssertFalse(TerminalHostIdentity.isLocal(host: Fixture.remoteHost, localHostName: ""))
    }

    func testPercentEncodedRemotePathIsDecodedAndKeepsItsHost() {
        var integration = TerminalShellIntegration()

        let event = integration.consumeOsc("7;file://\(Fixture.remoteHost)/srv/a%23b%20c")

        XCTAssertEqual(
            event,
            .workingDirectoryChanged(
                TerminalWorkingDirectoryLocation(path: "/srv/a#b c", remoteHost: Fixture.remoteHost)
            )
        )
    }

    func testLocationReportsRemoteness() {
        XCTAssertFalse(TerminalWorkingDirectoryLocation.local(Fixture.sharedPath).isRemote)
        XCTAssertTrue(
            TerminalWorkingDirectoryLocation(path: Fixture.sharedPath, remoteHost: Fixture.remoteHost).isRemote
        )
    }

    // MARK: - History grouping

    func testRemoteAndLocalEntriesWithTheSamePathNeverShareAGroup() {
        let groups = TerminalCommandHistoryRowBuilder.groups(
            entriesNewestFirst: [
                entry(command: Fixture.command, cwd: Fixture.sharedPath, host: Fixture.remoteUserHost),
                entry(command: "ls", cwd: Fixture.sharedPath, host: nil),
            ],
            filter: "",
            homeDirectory: Fixture.localHome
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].display.remoteHost, Fixture.remoteUserHost)
        XCTAssertTrue(groups[0].display.isRemote)
        XCTAssertNil(groups[1].display.remoteHost)
        XCTAssertFalse(groups[1].display.isRemote)
    }

    func testRemoteGroupTitleCarriesTheUserAtHostPrefix() {
        let display = TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: Fixture.sharedPath,
            homeDirectory: Fixture.localHome,
            remoteHost: Fixture.remoteUserHost
        )

        XCTAssertEqual(display.lastComponent, "app")
        XCTAssertEqual(display.parentDisplay, "\(Fixture.remoteUserHost):/srv")
        XCTAssertEqual(display.path, Fixture.sharedPath)
    }

    /// The local home prefix has no meaning on another machine, so remote
    /// paths are never abbreviated to `~`.
    func testRemotePathsAreNotHomeAbbreviated() {
        let remotePath = Fixture.localHome + "/project"
        let display = TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: remotePath,
            homeDirectory: Fixture.localHome,
            remoteHost: Fixture.remoteHost
        )

        XCTAssertEqual(display.parentDisplay, "\(Fixture.remoteHost):/Users/tester")
    }

    func testFilterMatchesTheRemoteHost() {
        let remoteEntry = entry(command: Fixture.command, cwd: Fixture.sharedPath, host: Fixture.remoteUserHost)
        let localEntry = entry(command: "ls", cwd: Fixture.sharedPath, host: nil)

        XCTAssertTrue(TerminalCommandHistoryRowBuilder.matches(entry: remoteEntry, filter: "build-box"))
        XCTAssertFalse(TerminalCommandHistoryRowBuilder.matches(entry: localEntry, filter: "build-box"))
    }

    // MARK: - History persistence and dedup

    @MainActor
    func testEntriesPersistedWithoutAHostDecodeAsLocal() throws {
        let legacyJSON = """
        [
          {
            "commandText": "swift test",
            "cwd": "\(Fixture.sharedPath)",
            "exitCode": 0,
            "finishedAt": "2026-01-01T00:00:00Z",
            "useCount": 1
          }
        ]
        """
        let historyURL = temporaryHistoryURL()
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(legacyJSON.utf8).write(to: historyURL)

        let store = TerminalCommandHistoryStore(
            historyURL: historyURL,
            isRecordingEnabled: true,
            observesSettingsChanges: false
        )
        let entries = store.entriesNewestFirst

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].cwdHost)
        XCTAssertFalse(entries[0].isRemote)
        XCTAssertEqual(entries[0].cwd, Fixture.sharedPath)
    }

    @MainActor
    func testRemoteAndLocalRepeatsOfTheSameCommandAreNotDeduplicatedTogether() {
        let store = TerminalCommandHistoryStore(
            historyURL: temporaryHistoryURL(),
            isRecordingEnabled: true,
            observesSettingsChanges: false
        )
        store.record(entry(command: Fixture.command, cwd: Fixture.sharedPath, host: nil))
        store.record(entry(command: Fixture.command, cwd: Fixture.sharedPath, host: Fixture.remoteUserHost))
        store.record(entry(command: Fixture.command, cwd: Fixture.sharedPath, host: Fixture.remoteUserHost))

        let entries = store.entriesNewestFirst
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].cwdHost, Fixture.remoteUserHost)
        XCTAssertEqual(entries[0].useCount, 2, "identical remote repeats still collapse")
        XCTAssertNil(entries[1].cwdHost)
    }

    @MainActor
    func testRecordedCompletionCarriesTheRemoteHostFromTheSpan() {
        let store = TerminalCommandHistoryStore(
            historyURL: temporaryHistoryURL(),
            isRecordingEnabled: true,
            observesSettingsChanges: false
        )
        let span = TerminalCommandSpan(
            id: 1,
            cwd: Fixture.sharedPath,
            cwdHost: Fixture.remoteUserHost,
            startBoundarySequence: 1,
            commandText: Fixture.command
        )
        store.record(
            completion: TerminalCommandCompletionContext(span: span, exitCode: 0, duration: 1)
        )

        XCTAssertEqual(store.entriesNewestFirst.first?.cwdHost, Fixture.remoteUserHost)
    }

    // MARK: - File explorer

    @MainActor
    func testRemoteLocationShortCircuitsListingWatchingAndGit() {
        let panel = TerminalFileExplorerPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 480)

        panel.update(
            location: TerminalWorkingDirectoryLocation(
                path: Fixture.sharedPath,
                remoteHost: Fixture.remoteUserHost
            )
        )
        panel.layoutSubtreeIfNeeded()

        XCTAssertNotNil(panel.remoteLocation)
        XCTAssertNil(panel.rootDirectory, "no local directory may be adopted for a remote session")
        XCTAssertEqual(panel.visibleRowCountForTesting, 0)
        XCTAssertFalse(panel.isRemoteEmptyStateHiddenForTesting)
        XCTAssertTrue(panel.remoteEmptyStateTextForTesting.contains(Fixture.remoteUserHost))
        XCTAssertTrue(panel.remoteEmptyStateTextForTesting.contains(Fixture.sharedPath))
        XCTAssertFalse(panel.isSearchEnabledForTesting)
    }

    /// A pane that keeps re-emitting OSC 7 for the same SSH directory must not
    /// rebuild the panel, or the tree flickers on every prompt.
    @MainActor
    func testRepeatingTheSameRemoteLocationIsIdempotent() {
        let panel = TerminalFileExplorerPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        let location = TerminalWorkingDirectoryLocation(
            path: Fixture.sharedPath,
            remoteHost: Fixture.remoteHost
        )

        panel.update(location: location)
        let firstText = panel.remoteEmptyStateTextForTesting
        panel.update(location: location)
        panel.refresh()

        XCTAssertEqual(panel.remoteLocation, location)
        XCTAssertEqual(panel.remoteEmptyStateTextForTesting, firstText)
        XCTAssertNil(panel.rootDirectory)
    }

    @MainActor
    func testReturningToALocalDirectoryClearsTheRemoteState() throws {
        let panel = TerminalFileExplorerPanelView()
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        let localDirectory = try makeTemporaryDirectory()

        panel.update(
            location: TerminalWorkingDirectoryLocation(
                path: Fixture.sharedPath,
                remoteHost: Fixture.remoteHost
            )
        )
        panel.update(location: .local(localDirectory.path))
        panel.layoutSubtreeIfNeeded()

        XCTAssertNil(panel.remoteLocation)
        XCTAssertEqual(panel.rootDirectory, localDirectory.standardizedFileURL)
        XCTAssertTrue(panel.isRemoteEmptyStateHiddenForTesting)
        XCTAssertTrue(panel.isSearchEnabledForTesting)
    }

    @MainActor
    func testRemoteEmptyStateIsLocalizedInEveryShippedLanguage() {
        for language in [AppLanguage.english, .korean, .japanese] {
            XCTAssertFalse(FileExplorerRemoteCopy.title(language: language).isEmpty)
            let explanation = FileExplorerRemoteCopy.explanation(
                hostPath: "\(Fixture.remoteUserHost):\(Fixture.sharedPath)",
                language: language
            )
            XCTAssertTrue(explanation.contains(Fixture.remoteUserHost), "\(language) explanation must name the host")
            XCTAssertFalse(explanation.contains("%@"), "\(language) explanation must substitute its argument")
        }
    }

    // MARK: - Helpers

    private func entry(command: String, cwd: String?, host: String?) -> TerminalCommandHistoryEntry {
        TerminalCommandHistoryEntry(
            commandText: command,
            cwd: cwd,
            cwdHost: host,
            exitCode: 0,
            finishedAt: Date()
        )
    }

    private func temporaryHistoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-remote-session-tests-\(UUID().uuidString)")
            .appendingPathComponent("command-history.json")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-remote-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
