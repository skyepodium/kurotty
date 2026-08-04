import AppKit
import XCTest
@testable import KurottyApp

final class TerminalCommandHistoryTests: XCTestCase {
    private enum Fixture {
        static let home = "/Users/tester"
        static let projectPath = "/Users/tester/dev/terminal"
        static let otherProjectPath = "/Users/tester/dev/site"
        static let systemPath = "/usr/local/bin"
        static let buildCommand = "swift build"
        static let testCommand = "swift test"
        static let capacity = 3
    }

    // MARK: - Store

    @MainActor
    private func makeStore(
        isRecordingEnabled: Bool = true,
        maximumEntryCount: Int = Fixture.capacity,
        historyURL: URL? = nil
    ) -> TerminalCommandHistoryStore {
        TerminalCommandHistoryStore(
            historyURL: historyURL ?? temporaryHistoryURL(),
            isRecordingEnabled: isRecordingEnabled,
            maximumEntryCount: maximumEntryCount,
            observesSettingsChanges: false
        )
    }

    private func temporaryHistoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-history-tests-\(UUID().uuidString)")
            .appendingPathComponent("command-history.json")
    }

    private func makeEntry(
        commandText: String = Fixture.buildCommand,
        cwd: String? = Fixture.projectPath,
        exitCode: Int? = 0,
        finishedAt: Date = Date()
    ) -> TerminalCommandHistoryEntry {
        TerminalCommandHistoryEntry(
            commandText: commandText,
            cwd: cwd,
            exitCode: exitCode,
            finishedAt: finishedAt
        )
    }

    @MainActor
    func testRecordAppendsTrimmedCommandNewestFirst() {
        let store = makeStore()
        store.record(makeEntry(commandText: "  \(Fixture.buildCommand)  "))
        store.record(makeEntry(commandText: Fixture.testCommand))

        let entries = store.entriesNewestFirst
        XCTAssertEqual(entries.map(\.commandText), [Fixture.testCommand, Fixture.buildCommand])
    }

    @MainActor
    func testEmptyAndWhitespaceCommandsAreSkipped() {
        let store = makeStore()
        store.record(makeEntry(commandText: ""))
        store.record(makeEntry(commandText: "   \n\t"))
        XCTAssertEqual(store.entryCount, 0)
    }

    @MainActor
    func testConsecutiveIdenticalCommandInSameDirectoryDeduplicates() {
        let store = makeStore()
        let laterDate = Date().addingTimeInterval(60)
        store.record(makeEntry(exitCode: 0))
        store.record(makeEntry(exitCode: 1, finishedAt: laterDate))

        let entries = store.entriesNewestFirst
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].useCount, 2)
        XCTAssertEqual(entries[0].exitCode, 1)
        XCTAssertEqual(entries[0].finishedAt, laterDate)
    }

    @MainActor
    func testSameCommandInDifferentDirectoryIsNotDeduplicated() {
        let store = makeStore()
        store.record(makeEntry(cwd: Fixture.projectPath))
        store.record(makeEntry(cwd: Fixture.otherProjectPath))
        XCTAssertEqual(store.entryCount, 2)
    }

    @MainActor
    func testCapacityEvictsOldestEntriesFirst() {
        let store = makeStore(maximumEntryCount: Fixture.capacity)
        for index in 0..<(Fixture.capacity + 2) {
            store.record(makeEntry(commandText: "echo \(index)"))
        }

        let commands = store.entriesNewestFirst.map(\.commandText)
        XCTAssertEqual(commands.count, Fixture.capacity)
        XCTAssertEqual(commands.first, "echo \(Fixture.capacity + 1)")
        XCTAssertFalse(commands.contains("echo 0"))
        XCTAssertFalse(commands.contains("echo 1"))
    }

    @MainActor
    func testPersistenceRoundTrip() {
        let historyURL = temporaryHistoryURL()
        let store = makeStore(historyURL: historyURL)
        store.record(makeEntry(commandText: Fixture.buildCommand, exitCode: 2))
        store.saveImmediately()

        let reloaded = makeStore(historyURL: historyURL)
        let entries = reloaded.entriesNewestFirst
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].commandText, Fixture.buildCommand)
        XCTAssertEqual(entries[0].cwd, Fixture.projectPath)
        XCTAssertEqual(entries[0].exitCode, 2)
    }

    @MainActor
    func testDisabledStoreShortCircuitsRecording() {
        let store = makeStore(isRecordingEnabled: false)
        store.record(makeEntry())
        XCTAssertEqual(store.entryCount, 0)
        XCTAssertFalse(store.isRecordingEnabled)

        store.setRecordingEnabled(true)
        store.record(makeEntry())
        XCTAssertEqual(store.entryCount, 1)
    }

    @MainActor
    func testRecordCompletionContextCapturesSpanMetadata() {
        let store = makeStore()
        let span = TerminalCommandSpan(
            id: 1,
            cwd: Fixture.projectPath,
            startBoundarySequence: 1,
            endBoundarySequence: 3,
            commandText: " \(Fixture.buildCommand) "
        )
        store.record(completion: TerminalCommandCompletionContext(span: span, exitCode: 0, duration: 1.5))

        let entries = store.entriesNewestFirst
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].commandText, Fixture.buildCommand)
        XCTAssertEqual(entries[0].cwd, Fixture.projectPath)
        XCTAssertEqual(entries[0].duration, 1.5)
        XCTAssertNotNil(entries[0].startedAt)
    }

    @MainActor
    func testCompletionContextWithoutCommandTextIsNotRecorded() {
        let store = makeStore()
        let span = TerminalCommandSpan(
            id: 1,
            cwd: Fixture.projectPath,
            startBoundarySequence: 1,
            endBoundarySequence: 3
        )
        store.record(completion: TerminalCommandCompletionContext(span: span, exitCode: 0, duration: nil))
        XCTAssertEqual(store.entryCount, 0)
    }

    // MARK: - Group building

    func testGroupsByWorkingDirectoryOrderedByMostRecentCommand() {
        let entriesNewestFirst = [
            makeEntry(commandText: Fixture.testCommand, cwd: Fixture.projectPath),
            makeEntry(commandText: "ls", cwd: Fixture.otherProjectPath),
            makeEntry(commandText: Fixture.buildCommand, cwd: Fixture.projectPath),
        ]
        let groups = TerminalCommandHistoryRowBuilder.groups(
            entriesNewestFirst: entriesNewestFirst,
            filter: "",
            homeDirectory: Fixture.home
        )

        guard groups.count == 2 else {
            return XCTFail("expected 2 directory groups, got \(groups)")
        }
        XCTAssertEqual(groups[0].display.path, Fixture.projectPath)
        XCTAssertEqual(
            groups[0].entriesNewestFirst.map(\.commandText),
            [Fixture.testCommand, Fixture.buildCommand],
            "commands inside a group stay newest first"
        )
        XCTAssertEqual(groups[1].display.path, Fixture.otherProjectPath)
        XCTAssertEqual(groups[1].entriesNewestFirst.map(\.commandText), ["ls"])
    }

    func testFilterMatchesCommandTextAndDirectoryCaseInsensitively() {
        let entry = makeEntry(commandText: "Swift Build", cwd: Fixture.projectPath)
        XCTAssertTrue(TerminalCommandHistoryRowBuilder.matches(entry: entry, filter: "swift"))
        XCTAssertTrue(TerminalCommandHistoryRowBuilder.matches(entry: entry, filter: "TERMINAL"))
        XCTAssertTrue(TerminalCommandHistoryRowBuilder.matches(entry: entry, filter: "swift terminal"))
        XCTAssertFalse(TerminalCommandHistoryRowBuilder.matches(entry: entry, filter: "zig"))
        XCTAssertTrue(TerminalCommandHistoryRowBuilder.matches(entry: entry, filter: "   "))
    }

    func testFilteredOutGroupsAreOmittedEntirely() {
        let groups = TerminalCommandHistoryRowBuilder.groups(
            entriesNewestFirst: [
                makeEntry(commandText: "swift build", cwd: Fixture.projectPath),
                makeEntry(commandText: "zig build", cwd: Fixture.systemPath),
            ],
            filter: "zig",
            homeDirectory: Fixture.home
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].display.path, Fixture.systemPath)
        XCTAssertEqual(groups[0].entriesNewestFirst.map(\.commandText), ["zig build"])
    }

    func testTrailingDetailLabelAppendsDimmedExitCodeOnlyForFailures() {
        let now = Date()
        let success = makeEntry(exitCode: 0, finishedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(TerminalCommandHistoryRowBuilder.trailingDetailLabel(for: success, now: now), "3m")

        let failure = makeEntry(exitCode: 1, finishedAt: now.addingTimeInterval(-180))
        XCTAssertEqual(TerminalCommandHistoryRowBuilder.trailingDetailLabel(for: failure, now: now), "3m · 1")

        let unknownExit = makeEntry(exitCode: nil, finishedAt: now)
        XCTAssertEqual(TerminalCommandHistoryRowBuilder.trailingDetailLabel(for: unknownExit, now: now), "now")
    }

    func testDirectoryDisplayAbbreviatesHomeAndSplitsComponents() {
        let display = TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: Fixture.projectPath,
            homeDirectory: Fixture.home
        )
        XCTAssertEqual(display.lastComponent, "terminal")
        XCTAssertEqual(display.parentDisplay, "~/dev")

        let homeDisplay = TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: Fixture.home,
            homeDirectory: Fixture.home
        )
        XCTAssertEqual(homeDisplay.lastComponent, "~")
        XCTAssertEqual(homeDisplay.parentDisplay, "")

        let systemDisplay = TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: Fixture.systemPath,
            homeDirectory: Fixture.home
        )
        XCTAssertEqual(systemDisplay.lastComponent, "bin")
        XCTAssertEqual(systemDisplay.parentDisplay, "/usr/local")

        let unknownDisplay = TerminalCommandHistoryRowBuilder.directoryDisplay(
            for: "  ",
            homeDirectory: Fixture.home
        )
        XCTAssertEqual(unknownDisplay.path, "")
        XCTAssertFalse(unknownDisplay.lastComponent.isEmpty)
    }

    func testRelativeTimeLabelEdgeCases() {
        let now = Date()
        XCTAssertEqual(TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: now, to: now), "now")
        XCTAssertEqual(
            TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: now.addingTimeInterval(30), to: now),
            "now",
            "future timestamps clamp to now"
        )
        XCTAssertEqual(
            TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: now.addingTimeInterval(-59), to: now),
            "now"
        )
        XCTAssertEqual(
            TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: now.addingTimeInterval(-180), to: now),
            "3m"
        )
        XCTAssertEqual(
            TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: now.addingTimeInterval(-7_200), to: now),
            "2h"
        )
        XCTAssertEqual(
            TerminalCommandHistoryRowBuilder.relativeTimeLabel(from: now.addingTimeInterval(-432_000), to: now),
            "5d"
        )
    }

    // MARK: - Replay approval gating

    func testHistoryReplayCandidateAlwaysRequiresExplicitConfirmation() throws {
        let candidate = try XCTUnwrap(
            TerminalCommandHistoryReplay.replayCandidate(for: makeEntry(commandText: Fixture.buildCommand))
        )
        XCTAssertTrue(candidate.requiresExplicitUserConfirmation)
        XCTAssertEqual(candidate.commandText, Fixture.buildCommand)
    }

    func testEmptyCommandProducesNoReplayCandidate() {
        XCTAssertNil(TerminalCommandHistoryReplay.replayCandidate(for: makeEntry(commandText: "  ")))
    }

    func testUnconfirmedHistoryReplayIsRefusedByDispatcher() throws {
        let candidate = try XCTUnwrap(
            TerminalCommandHistoryReplay.replayCandidate(for: makeEntry(commandText: Fixture.buildCommand))
        )
        let replayCommand = try XCTUnwrap(TerminalCommandDispatcher.commandSpanCommand(for: .replay))
        var replayedCommandText: String?
        let handlers = TerminalCommandSpanDispatchHandlers(
            replay: { candidate, _ in
                replayedCommandText = candidate.commandText
            }
        )

        let refused = TerminalCommandDispatcher.execute(
            replayCommand,
            context: .replay(candidate, approval: TerminalCommandReplayApproval(isExplicitlyConfirmed: false)),
            handlers: handlers
        )
        XCTAssertEqual(refused, .requiresApproval)
        XCTAssertNil(replayedCommandText)

        let dispatched = TerminalCommandDispatcher.execute(
            replayCommand,
            context: .replay(candidate, approval: TerminalCommandReplayApproval(isExplicitlyConfirmed: true)),
            handlers: handlers
        )
        XCTAssertEqual(dispatched, .dispatched)
        XCTAssertEqual(replayedCommandText, Fixture.buildCommand)
    }

    // MARK: - Command registry and shortcuts

    func testTogglePanelCommandIsRegisteredWithoutShortcutConflicts() throws {
        let commands = TerminalCommandRegistry.default.windowCommands
        let toggleCommand = try XCTUnwrap(
            commands.first { $0.id == .toggleCommandHistoryPanel }
        )
        XCTAssertEqual(toggleCommand.id.rawValue, "history.togglePanel")
        XCTAssertEqual(toggleCommand.shortcut?.keyEquivalent, "y")
        XCTAssertEqual(
            commands.filter { $0.shortcut?.keyEquivalent == "y" }.count,
            1,
            "Cmd+Shift+Y must stay unique to the history panel toggle"
        )
    }

    // MARK: - Window integration

    @MainActor
    private func makeWindowController() -> TerminalWindowController {
        let session = TmuxPaneSession(
            writeHandler: { _ in },
            resizeHandler: { _, _ in },
            stopHandler: {}
        )
        return TerminalWindowController(
            detachedPane: TerminalPaneView(frame: .zero, session: session),
            paneDragCoordinator: TerminalPaneDragCoordinator()
        )
    }

    @MainActor
    func testCommandHistoryPanelStartsHiddenAndToggles() {
        let controller = makeWindowController()
        // Leaked controllers keep observing global notifications and
        // destabilize unrelated suites, so close deterministically.
        defer { controller.close() }

        XCTAssertFalse(controller.isCommandHistoryPanelVisible)
        controller.toggleCommandHistoryPanel()
        XCTAssertTrue(controller.isCommandHistoryPanelVisible)
        controller.toggleCommandHistoryPanel()
        XCTAssertFalse(controller.isCommandHistoryPanelVisible)
    }

    // MARK: - Sidebar outline panel

    @MainActor
    func testPanelGroupsAndDefaultExpansionFollowRecency() {
        let store = makeStore(maximumEntryCount: 100)
        let now = Date()
        let directories = ["/Users/tester/dev/a", "/Users/tester/dev/b", "/Users/tester/dev/c", "/Users/tester/dev/d"]
        for (index, directory) in directories.enumerated() {
            store.record(makeEntry(
                commandText: "echo \(index)",
                cwd: directory,
                finishedAt: now.addingTimeInterval(TimeInterval(index))
            ))
        }
        let panel = TerminalCommandHistoryPanelView(store: store)
        panel.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        panel.layoutSubtreeIfNeeded()

        let groups = panel.visibleGroupsForTesting
        XCTAssertEqual(groups.count, directories.count)
        XCTAssertEqual(groups[0].display.path, directories.last, "most recent directory leads")

        // The three most recent groups are expanded by default; older groups
        // start collapsed.
        XCTAssertTrue(panel.isGroupExpandedForTesting(path: groups[0].display.path))
        XCTAssertTrue(panel.isGroupExpandedForTesting(path: groups[1].display.path))
        XCTAssertTrue(panel.isGroupExpandedForTesting(path: groups[2].display.path))
        XCTAssertFalse(panel.isGroupExpandedForTesting(path: groups[3].display.path))
    }

    // MARK: - Debug preview seeding

    @MainActor
    func testDebugSeedEntriesStayInMemoryAndNeverPersist() {
        let historyURL = temporaryHistoryURL()
        let store = makeStore(historyURL: historyURL)
        store.seedInMemoryEntriesForDebugPreview(
            TerminalCommandHistoryDebugSeed.sampleEntries(homeDirectory: Fixture.home)
        )
        XCTAssertGreaterThanOrEqual(store.entryCount, 12)
        store.saveImmediately()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: historyURL.path),
            "debug seed data must never reach disk"
        )
    }

    func testDebugSeedCoversThreeDirectoriesWithFailures() {
        let entries = TerminalCommandHistoryDebugSeed.sampleEntries(homeDirectory: Fixture.home, now: Date())
        let directories = Set(entries.compactMap(\.cwd))
        XCTAssertEqual(directories.count, 3)
        XCTAssertTrue(entries.contains { ($0.exitCode ?? 0) != 0 }, "seed data must include failures")
        XCTAssertTrue(entries.allSatisfy { $0.cwd?.hasPrefix(Fixture.home + "/") == true })
    }

    func testHistoryPanelDebugFlagsFollowTheExistingFlagPattern() throws {
        let debugSource = try sourceFile("Sources/KurottyApp/DebugOptions.swift")
        XCTAssertTrue(debugSource.contains("--debug-show-history-panel"))
        XCTAssertTrue(debugSource.contains("KUROTTY_DEBUG_SHOW_HISTORY_PANEL"))
        XCTAssertTrue(debugSource.contains("--debug-seed-history"))
        XCTAssertTrue(debugSource.contains("KUROTTY_DEBUG_SEED_HISTORY"))

        let appDelegateSource = try sourceFile("Sources/KurottyApp/AppDelegate.swift")
        XCTAssertTrue(appDelegateSource.contains("if DebugOptions.showHistoryPanel"))
        XCTAssertTrue(appDelegateSource.contains("if DebugOptions.seedHistory"))
        XCTAssertTrue(
            appDelegateSource.contains("seedInMemoryEntriesForDebugPreview"),
            "seeding must use the in-memory-only store entry point"
        )
    }

    // MARK: - Settings schema

    func testSettingsWithoutCommandHistoryKeyDefaultToEnabled() throws {
        let legacyJSON = """
        {
          "schemaVersion": 9,
          "terminal": {
            "theme": "kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 100000,
            "colors": {
              "foreground": "#E5E7EB",
              "background": "#22252B",
              "cursor": "#D7C6F4",
              "ansi": \(ansiJSONArray())
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        let normalized = AppSettingsNormalizer.normalized(decoded)
        XCTAssertTrue(normalized.terminal.commandHistoryEnabled)
        XCTAssertEqual(normalized.schemaVersion, AppSettings.default.schemaVersion)
    }

    func testDisabledCommandHistorySettingSurvivesNormalizationAndRoundTrip() throws {
        var settings = AppSettings.default
        settings.terminal.commandHistoryEnabled = false
        let normalized = AppSettingsNormalizer.normalized(settings)
        XCTAssertFalse(normalized.terminal.commandHistoryEnabled)

        let data = try JSONEncoder().encode(normalized)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.terminal.commandHistoryEnabled)
    }

    private func ansiJSONArray() -> String {
        let colors = TerminalColorSettings.default.ansi
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        return "[\(colors)]"
    }

    // MARK: - Source shape

    func testCompletionPathRecordsIntoHistoryStore() throws {
        let surfaceSource = try sourceFile("Sources/KurottyApp/TerminalSurfaceView.swift")
        XCTAssertTrue(
            surfaceSource.contains("TerminalCommandHistoryStore.shared.record(completion: context)"),
            "command completion must feed the persistent history store"
        )
    }

    func testInsertSendsCommandTextWithoutNewline() throws {
        let integrationSource = try sourceFile("Sources/KurottyApp/TerminalWindowCommandHistory.swift")
        XCTAssertTrue(
            integrationSource.contains("sendTextToActivePane(entry.commandText)"),
            "insert must send the raw command text"
        )
        XCTAssertFalse(
            integrationSource.contains("sendTextToActivePane(entry.commandText + \"\\n\")"),
            "insert must never append a newline"
        )
    }

    func testRunAgainRoutesThroughReplayApprovalGate() throws {
        let integrationSource = try sourceFile("Sources/KurottyApp/TerminalWindowCommandHistory.swift")
        XCTAssertTrue(
            integrationSource.contains("TerminalCommandDispatcher.execute"),
            "run again must go through the replay dispatcher"
        )
        XCTAssertTrue(
            integrationSource.contains(".replay(candidate, approval: approval)"),
            "run again must carry an explicit approval context"
        )
        XCTAssertTrue(
            integrationSource.contains("guard result == .dispatched"),
            "the newline send must be gated on a dispatched replay"
        )
    }

    func testMainMenuExposesCommandHistoryToggle() throws {
        let menuSource = try sourceFile("Sources/KurottyApp/MainMenu.swift")
        XCTAssertTrue(menuSource.contains("AppDelegate.toggleCommandHistoryPanel"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \"y\""))
    }
}

private func sourceFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: sourceRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func sourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
