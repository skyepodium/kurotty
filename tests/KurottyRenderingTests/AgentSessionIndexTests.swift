import XCTest
@testable import KurottyApp
@testable import KurottyCore

final class AgentSessionIndexTests: XCTestCase {
    private enum Fixture {
        static let claudeSessionID = "67dda2d5-4c26-4cb7-a3ea-d45504caee3f"
        static let codexSessionID = "019fccbf-1938-75e3-aaa3-3910d856eb45"
        static let codexFileName = "rollout-2026-08-04T21-28-23-019fccbf-1938-75e3-aaa3-3910d856eb45.jsonl"
        static let projectDirectory = "/Users/tester/dev/terminal/kurotty"
        static let secondDirectory = "/Users/tester/dev/toonatic"
        static let homeDirectory = "/Users/tester"
        static let gitBranch = "feature/agent-session-vault"
        static let aiTitle = "Agent session vault"
        static let customTitle = "Vault work"
        static let lastPrompt = "run the tests again"
        static let firstPrompt = "add an agent session index"
        static let earlierTimestamp = "2026-08-04T10:00:00.000Z"
        static let laterTimestamp = "2026-08-04T12:30:15.500Z"
    }

    private func claudeFileURL(sessionID: String = Fixture.claudeSessionID) -> URL {
        URL(fileURLWithPath: "/Users/tester/.claude/projects/-Users-tester-dev/\(sessionID).jsonl")
    }

    private func codexFileURL(fileName: String = Fixture.codexFileName) -> URL {
        URL(fileURLWithPath: "/Users/tester/.codex/sessions/2026/08/04/\(fileName)")
    }

    // MARK: - Claude transcript parsing

    private func claudeTranscriptLines() -> [String] {
        [
            """
            {"type":"user","sessionId":"\(Fixture.claudeSessionID)","cwd":"\(Fixture.projectDirectory)",\
            "gitBranch":"\(Fixture.gitBranch)","timestamp":"\(Fixture.earlierTimestamp)","version":"2.0.0",\
            "message":{"role":"user","content":"\(Fixture.firstPrompt)"}}
            """,
            """
            {"type":"assistant","sessionId":"\(Fixture.claudeSessionID)","cwd":"\(Fixture.projectDirectory)",\
            "gitBranch":"\(Fixture.gitBranch)","timestamp":"\(Fixture.laterTimestamp)",\
            "message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}
            """,
            "{\"type\":\"ai-title\",\"aiTitle\":\"\(Fixture.aiTitle)\",\"sessionId\":\"\(Fixture.claudeSessionID)\"}",
            "{\"type\":\"last-prompt\",\"lastPrompt\":\"\(Fixture.lastPrompt)\",\"sessionId\":\"\(Fixture.claudeSessionID)\"}",
        ]
    }

    func testClaudeParserExtractsTitleDirectoryBranchAndTimestamps() throws {
        let scanner = ClaudeSessionScanner()
        let record = try XCTUnwrap(scanner.parse(
            lines: claudeTranscriptLines(),
            fileURL: claudeFileURL(),
            modifiedAt: Date(timeIntervalSince1970: 0)
        ))

        XCTAssertEqual(record.agent, .claudeCode)
        XCTAssertEqual(record.sessionID, Fixture.claudeSessionID)
        XCTAssertEqual(record.title, Fixture.aiTitle)
        XCTAssertEqual(record.cwd, Fixture.projectDirectory)
        XCTAssertEqual(record.gitBranch, Fixture.gitBranch)
        XCTAssertEqual(record.messageCount, 2)
        XCTAssertFalse(record.isTranscriptTruncated)
        XCTAssertEqual(record.firstUserPrompt, Fixture.firstPrompt)
        XCTAssertEqual(record.lastUserPrompt, Fixture.lastPrompt)
        XCTAssertEqual(record.filePath, claudeFileURL().path)
        XCTAssertLessThan(record.createdAt, record.updatedAt)
    }

    func testClaudeCustomTitleWinsOverAITitle() throws {
        let scanner = ClaudeSessionScanner()
        var lines = claudeTranscriptLines()
        lines.append(
            "{\"type\":\"custom-title\",\"customTitle\":\"\(Fixture.customTitle)\",\"sessionId\":\"\(Fixture.claudeSessionID)\"}"
        )
        let record = try XCTUnwrap(scanner.parse(
            lines: lines,
            fileURL: claudeFileURL(),
            modifiedAt: Date()
        ))
        XCTAssertEqual(record.title, Fixture.customTitle)
    }

    func testClaudeParserHandlesStringAndArrayMessageContent() throws {
        let scanner = ClaudeSessionScanner()
        let arrayContent = """
        {"type":"user","sessionId":"s1","cwd":"\(Fixture.projectDirectory)","timestamp":"\(Fixture.earlierTimestamp)",\
        "message":{"role":"user","content":[{"type":"text","text":"first block"},{"type":"text","text":"second block"}]}}
        """
        let record = try XCTUnwrap(scanner.parse(
            lines: [arrayContent],
            fileURL: claudeFileURL(),
            modifiedAt: Date()
        ))
        XCTAssertEqual(record.firstUserPrompt, "first block\nsecond block")
        XCTAssertEqual(record.title, "first block")
    }

    func testClaudeParserFallsBackToFirstPromptWhenNoTitleRecordExists() throws {
        let scanner = ClaudeSessionScanner()
        let line = """
        {"type":"user","sessionId":"s2","cwd":"\(Fixture.projectDirectory)","timestamp":"\(Fixture.earlierTimestamp)",\
        "message":{"role":"user","content":"\(Fixture.firstPrompt)\\nmore detail"}}
        """
        let record = try XCTUnwrap(scanner.parse(lines: [line], fileURL: claudeFileURL(), modifiedAt: Date()))
        XCTAssertEqual(record.title, Fixture.firstPrompt)
    }

    func testClaudeParserIgnoresMalformedAndPartialLines() throws {
        let scanner = ClaudeSessionScanner()
        var lines = claudeTranscriptLines()
        lines.insert("not json at all", at: 0)
        lines.insert("{\"type\":\"user\",\"sessionId\":\"trunc", at: 1)
        lines.append("")
        let record = try XCTUnwrap(scanner.parse(lines: lines, fileURL: claudeFileURL(), modifiedAt: Date()))
        XCTAssertEqual(record.sessionID, Fixture.claudeSessionID)
        XCTAssertEqual(record.messageCount, 2, "malformed lines must not be counted as messages")
    }

    func testClaudeParserReturnsNilForEmptyTranscript() {
        let scanner = ClaudeSessionScanner()
        XCTAssertNil(scanner.parse(contents: "", fileURL: claudeFileURL(), modifiedAt: Date(), isTranscriptTruncated: false))
        XCTAssertNil(scanner.parse(contents: "\n\n", fileURL: claudeFileURL(), modifiedAt: Date(), isTranscriptTruncated: false))
    }

    func testClaudeParserFallsBackToFileNameSessionIdentifier() throws {
        let scanner = ClaudeSessionScanner()
        let line = "{\"type\":\"user\",\"cwd\":\"\(Fixture.projectDirectory)\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try XCTUnwrap(scanner.parse(lines: [line], fileURL: claudeFileURL(), modifiedAt: modifiedAt))
        XCTAssertEqual(record.sessionID, Fixture.claudeSessionID)
        XCTAssertEqual(record.updatedAt, modifiedAt, "a transcript without timestamps falls back to the file date")
    }

    // MARK: - Codex transcript parsing

    func testCodexSessionIdentifierIsDerivedFromRolloutFileName() {
        XCTAssertEqual(
            CodexSessionScanner.sessionID(fromFileName: Fixture.codexFileName),
            Fixture.codexSessionID
        )
    }

    func testCodexSessionIdentifierFallsBackWhenFileNameHasNoUUID() {
        XCTAssertEqual(
            CodexSessionScanner.sessionID(fromFileName: "rollout-not-a-uuid.jsonl"),
            "not-a-uuid"
        )
    }

    func testCodexParserExtractsDirectoryTitleAndMessageCount() throws {
        let scanner = CodexSessionScanner()
        let lines = [
            """
            {"timestamp":"\(Fixture.earlierTimestamp)","type":"session_meta","payload":{"session_id":"\(Fixture.codexSessionID)",\
            "cwd":"\(Fixture.projectDirectory)","originator":"Codex Desktop"}}
            """,
            """
            {"timestamp":"\(Fixture.earlierTimestamp)","type":"response_item","payload":{"type":"message","role":"user",\
            "content":[{"type":"input_text","text":"\(Fixture.firstPrompt)"}]}}
            """,
            """
            {"timestamp":"\(Fixture.laterTimestamp)","type":"response_item","payload":{"type":"message","role":"assistant",\
            "content":[{"type":"output_text","text":"done"}]}}
            """,
            "{\"timestamp\":\"\(Fixture.laterTimestamp)\",\"type\":\"unknown_future_record\",\"payload\":{\"anything\":1}}",
        ]
        let record = try XCTUnwrap(scanner.parse(
            lines: lines,
            fileURL: codexFileURL(),
            modifiedAt: Date()
        ))

        XCTAssertEqual(record.agent, .codex)
        XCTAssertEqual(record.sessionID, Fixture.codexSessionID)
        XCTAssertEqual(record.cwd, Fixture.projectDirectory)
        XCTAssertEqual(record.title, Fixture.firstPrompt)
        XCTAssertEqual(record.messageCount, 2)
        XCTAssertNil(record.gitBranch)
    }

    func testCodexTypedPromptWinsOverInjectedTranscriptContext() throws {
        let scanner = CodexSessionScanner()
        let lines = [
            """
            {"timestamp":"\(Fixture.earlierTimestamp)","type":"response_item","payload":{"type":"message","role":"user",\
            "content":[{"type":"input_text","text":"Here is a list of plugins available in this workspace"}]}}
            """,
            """
            {"timestamp":"\(Fixture.laterTimestamp)","type":"event_msg","payload":{"type":"user_message",\
            "message":"\(Fixture.firstPrompt)"}}
            """,
        ]
        let record = try XCTUnwrap(scanner.parse(lines: lines, fileURL: codexFileURL(), modifiedAt: Date()))
        XCTAssertEqual(
            record.title,
            Fixture.firstPrompt,
            "injected workspace/plugin context must never become the session title"
        )
        XCTAssertEqual(record.firstUserPrompt, Fixture.firstPrompt)
    }

    func testCodexParserFindsNestedWorkingDirectoryWithoutSessionMeta() throws {
        let scanner = CodexSessionScanner()
        let lines = [
            """
            {"timestamp":"\(Fixture.earlierTimestamp)","type":"turn_context","payload":{"context":\
            {"working_directory":"\(Fixture.secondDirectory)"}}}
            """,
            """
            {"timestamp":"\(Fixture.laterTimestamp)","type":"event_msg","payload":{"type":"user_message",\
            "message":"ship it"}}
            """,
        ]
        let record = try XCTUnwrap(scanner.parse(lines: lines, fileURL: codexFileURL(), modifiedAt: Date()))
        XCTAssertEqual(record.cwd, Fixture.secondDirectory)
        XCTAssertEqual(record.title, "ship it")
    }

    func testCodexParserReturnsNilForEmptyTranscript() {
        let scanner = CodexSessionScanner()
        XCTAssertNil(scanner.parse(contents: "", fileURL: codexFileURL(), modifiedAt: Date(), isTranscriptTruncated: false))
    }

    // MARK: - File walking against a temporary tree

    func testFileWalkerFindsTranscriptsUnderAnInjectedRoot() throws {
        // Never read the real ~/.claude: every walk test builds its own tree.
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDirectory = root.appendingPathComponent(".claude/projects/-Users-tester-dev")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let transcriptURL = projectDirectory.appendingPathComponent("\(Fixture.claudeSessionID).jsonl")
        try claudeTranscriptLines().joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "ignore me".write(
            to: projectDirectory.appendingPathComponent("notes.txt"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = ClaudeSessionScanner()
        let urls = scanner.sessionFileURLs(
            rootURL: scanner.rootURL(homeDirectory: root),
            fileManager: FileManager.default
        )
        XCTAssertEqual(urls.map(\.lastPathComponent), ["\(Fixture.claudeSessionID).jsonl"])

        let contents = try String(contentsOf: transcriptURL, encoding: .utf8)
        let record = try XCTUnwrap(scanner.parse(
            contents: contents,
            fileURL: transcriptURL,
            modifiedAt: Date(),
            isTranscriptTruncated: false
        ))
        XCTAssertEqual(record.title, Fixture.aiTitle)
    }

    func testMissingRootDirectoryYieldsNoTranscripts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = CodexSessionScanner()
        XCTAssertTrue(scanner.sessionFileURLs(
            rootURL: scanner.rootURL(homeDirectory: root),
            fileManager: FileManager.default
        ).isEmpty)
    }

    func testBoundedReaderReadsSmallTranscriptsWhole() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("small.jsonl")
        let contents = claudeTranscriptLines().joined(separator: "\n")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        let sizeBytes = contents.utf8.count

        let result = try XCTUnwrap(AgentSessionTranscriptReader.read(fileURL: fileURL, sizeBytes: sizeBytes))
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.contents, contents)
    }

    func testBoundedReaderSkipsTranscriptsAboveTheSizeCap() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("huge.jsonl")
        try "{}".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertNil(AgentSessionTranscriptReader.read(
            fileURL: fileURL,
            sizeBytes: AppConstants.AgentSessions.maximumTranscriptBytes + 1
        ))
        XCTAssertNil(AgentSessionTranscriptReader.read(fileURL: fileURL, sizeBytes: 0))
    }

    // MARK: - Grouping, sorting, filtering

    private func makeRecord(
        agent: AgentSessionKind = .claudeCode,
        sessionID: String,
        title: String,
        cwd: String = Fixture.projectDirectory,
        updatedAgeSeconds: TimeInterval = 0,
        createdAgeSeconds: TimeInterval? = nil,
        messageCount: Int = 4,
        isTranscriptTruncated: Bool = false,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            agent: agent,
            sessionID: sessionID,
            title: title,
            cwd: cwd,
            gitBranch: Fixture.gitBranch,
            updatedAt: now.addingTimeInterval(-updatedAgeSeconds),
            createdAt: now.addingTimeInterval(-(createdAgeSeconds ?? updatedAgeSeconds)),
            messageCount: messageCount,
            isTranscriptTruncated: isTranscriptTruncated,
            firstUserPrompt: title,
            lastUserPrompt: title,
            filePath: "/tmp/\(sessionID).jsonl"
        )
    }

    func testGroupsAreKeyedByProjectAndOrderedByRecency() {
        let records = [
            makeRecord(sessionID: "old", title: "older kurotty work", updatedAgeSeconds: 5_000),
            makeRecord(sessionID: "other", title: "toonatic work", cwd: Fixture.secondDirectory, updatedAgeSeconds: 100),
            makeRecord(sessionID: "new", title: "newest kurotty work", updatedAgeSeconds: 10),
        ]
        let groups = AgentSessionRowBuilder.groups(
            records: records,
            homeDirectory: Fixture.homeDirectory
        )
        XCTAssertEqual(groups.map(\.display.lastComponent), ["kurotty", "toonatic"])
        XCTAssertEqual(groups[0].sessionsNewestFirst.map(\.sessionID), ["new", "old"])
        XCTAssertEqual(groups[0].display.parentDisplay, "~/dev/terminal")
    }

    func testGroupingByFolderAndAgent() {
        let records = [
            makeRecord(sessionID: "a", title: "kurotty", updatedAgeSeconds: 10),
            makeRecord(agent: .codex, sessionID: "b", title: "toonatic", cwd: Fixture.secondDirectory, updatedAgeSeconds: 20),
        ]

        let folderGroups = AgentSessionRowBuilder.groups(
            records: records,
            grouping: .folder,
            homeDirectory: Fixture.homeDirectory
        )
        XCTAssertEqual(folderGroups.map(\.display.lastComponent), ["terminal", "dev"])

        let agentGroups = AgentSessionRowBuilder.groups(
            records: records,
            grouping: .agent,
            homeDirectory: Fixture.homeDirectory
        )
        XCTAssertEqual(agentGroups.map(\.display.lastComponent), ["Claude Code", "Codex"])
    }

    func testSortingByCreatedDiffersFromSortingByUpdated() {
        let records = [
            makeRecord(sessionID: "recently-updated", title: "one", updatedAgeSeconds: 10, createdAgeSeconds: 9_000),
            makeRecord(sessionID: "recently-created", title: "two", updatedAgeSeconds: 500, createdAgeSeconds: 500),
        ]
        XCTAssertEqual(
            AgentSessionRowBuilder.sorted(records, by: .updated).map(\.sessionID),
            ["recently-updated", "recently-created"]
        )
        XCTAssertEqual(
            AgentSessionRowBuilder.sorted(records, by: .created).map(\.sessionID),
            ["recently-created", "recently-updated"]
        )
    }

    func testFilterMatchesSubstringAndFuzzyQueries() {
        let record = makeRecord(sessionID: "one", title: "Agent session vault")
        XCTAssertTrue(AgentSessionRowBuilder.matches(record: record, filter: ""))
        XCTAssertTrue(AgentSessionRowBuilder.matches(record: record, filter: "vault"))
        XCTAssertTrue(AgentSessionRowBuilder.matches(record: record, filter: "kurotty"), "cwd is searchable")
        XCTAssertTrue(AgentSessionRowBuilder.matches(record: record, filter: "claude"), "agent name is searchable")
        XCTAssertTrue(AgentSessionRowBuilder.matches(record: record, filter: "agnt"), "fuzzy subsequence matches")
        XCTAssertTrue(AgentSessionRowBuilder.matches(record: record, filter: "vault agent"), "all tokens must match")
        XCTAssertFalse(AgentSessionRowBuilder.matches(record: record, filter: "zzzz"))
    }

    func testMessageCountLabelMarksPartiallyReadTranscripts() {
        XCTAssertEqual(
            AgentSessionRowBuilder.messageCountLabel(
                for: makeRecord(sessionID: "a", title: "t", messageCount: 12)
            ),
            "12"
        )
        XCTAssertEqual(
            AgentSessionRowBuilder.messageCountLabel(
                for: makeRecord(sessionID: "b", title: "t", messageCount: 12, isTranscriptTruncated: true)
            ),
            "12+"
        )
    }

    func testDirectoryLabelIsHomeAbbreviated() {
        let record = makeRecord(sessionID: "a", title: "t")
        XCTAssertEqual(
            AgentSessionRowBuilder.directoryLabel(for: record, homeDirectory: Fixture.homeDirectory),
            "~/dev/terminal/kurotty"
        )
    }

    // MARK: - Resume command construction

    func testResumeCommandForClaudeSession() {
        let record = makeRecord(sessionID: Fixture.claudeSessionID, title: "t")
        XCTAssertEqual(
            AgentSessionResumeCommand.command(for: record),
            "cd '\(Fixture.projectDirectory)' && claude --resume \(Fixture.claudeSessionID)"
        )
    }

    func testResumeCommandForCodexSession() {
        let record = makeRecord(agent: .codex, sessionID: Fixture.codexSessionID, title: "t")
        XCTAssertEqual(
            AgentSessionResumeCommand.command(for: record),
            "cd '\(Fixture.projectDirectory)' && codex resume \(Fixture.codexSessionID)"
        )
    }

    func testResumeCommandQuotesDirectoriesWithSpacesAndQuotes() {
        let spaced = makeRecord(sessionID: "s", title: "t", cwd: "/Users/tester/my projects/app")
        XCTAssertEqual(
            AgentSessionResumeCommand.command(for: spaced),
            "cd '/Users/tester/my projects/app' && claude --resume s"
        )

        let quoted = makeRecord(sessionID: "s", title: "t", cwd: "/Users/tester/it's mine")
        XCTAssertEqual(
            AgentSessionResumeCommand.command(for: quoted),
            "cd '/Users/tester/it'\\''s mine' && claude --resume s"
        )
    }

    func testResumeCommandQuotesUnsafeSessionIdentifiersAndSkipsEmptyDirectory() {
        let record = makeRecord(sessionID: "id with space; rm -rf /", title: "t", cwd: "")
        XCTAssertEqual(
            AgentSessionResumeCommand.command(for: record),
            "claude --resume 'id with space; rm -rf /'"
        )
    }

    // MARK: - Settings gate

    func testAgentSessionIndexDefaultsToEnabled() {
        XCTAssertTrue(SettingsDefaults.agentSessionIndexEnabled)
        XCTAssertTrue(AppSettings.default.terminal.agentSessionIndexEnabled)
    }

    func testSettingsWrittenBeforeSchemaElevenNormalizeToTheCurrentDefault() throws {
        var settings = AppSettings.default
        settings.schemaVersion = 10
        settings.terminal.agentSessionIndexEnabled = false
        let normalized = AppSettingsNormalizer.normalized(settings)
        XCTAssertEqual(normalized.schemaVersion, SettingsDefaults.schemaVersion)
        XCTAssertEqual(
            normalized.terminal.agentSessionIndexEnabled,
            SettingsDefaults.agentSessionIndexEnabled,
            "a pre-schema-11 file carries no user intent for this key"
        )
    }

    func testCurrentSchemaSettingsPreserveAnExplicitOptOut() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.agentSessionIndexEnabled = false
        XCTAssertFalse(
            AppSettingsNormalizer.normalized(settings).terminal.agentSessionIndexEnabled,
            "turning the index off in Settings must survive normalization"
        )
    }

    func testCurrentSchemaSettingsPreserveAnExplicitOptIn() {
        var settings = AppSettings.default
        settings.schemaVersion = SettingsDefaults.schemaVersion
        settings.terminal.agentSessionIndexEnabled = true
        XCTAssertTrue(AppSettingsNormalizer.normalized(settings).terminal.agentSessionIndexEnabled)
    }

    func testDecodingSettingsWithoutTheKeyUsesTheDefault() throws {
        let json = """
        {
          "schemaVersion": \(SettingsDefaults.schemaVersion),
          "terminal": {
            "theme": "Kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 10000,
            "colors": {
              "foreground": "\(TerminalColorDefaults.foregroundHex)",
              "background": "\(TerminalColorDefaults.backgroundHex)",
              "cursor": "\(TerminalColorDefaults.cursorHex)",
              "ansi": \(ansiJSONArray())
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.terminal.agentSessionIndexEnabled, SettingsDefaults.agentSessionIndexEnabled)
    }

    func testDecodingSettingsWithAnExplicitOptOutIsHonored() throws {
        let json = """
        {
          "schemaVersion": \(SettingsDefaults.schemaVersion),
          "terminal": {
            "theme": "Kurotty",
            "fontName": "Menlo",
            "fontSize": 15,
            "scrollbackLines": 10000,
            "agentSessionIndexEnabled": false,
            "colors": {
              "foreground": "\(TerminalColorDefaults.foregroundHex)",
              "background": "\(TerminalColorDefaults.backgroundHex)",
              "cursor": "\(TerminalColorDefaults.cursorHex)",
              "ansi": \(ansiJSONArray())
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.terminal.agentSessionIndexEnabled)
    }

    @MainActor
    func testDisabledStoreShortCircuitsScanningAndDropsRecords() {
        let store = AgentSessionIndexStore(
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home-for-tests"),
            scanners: [FailingScanner()],
            isIndexingEnabled: false,
            observesSettingsChanges: false
        )
        store.refresh()
        XCTAssertFalse(store.isScanning, "a disabled store must never start a background scan")
        XCTAssertTrue(store.records.isEmpty)

        store.setRecordsForTesting([makeRecord(sessionID: "seeded", title: "t")])
        XCTAssertEqual(store.records.count, 1)
        store.setIndexingEnabled(false)
        XCTAssertEqual(store.records.count, 1, "already disabled: no state change")
    }

    @MainActor
    func testTurningIndexingOffDropsEveryIndexedRecord() {
        let store = AgentSessionIndexStore(
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home-for-tests"),
            scanners: [],
            isIndexingEnabled: true,
            observesSettingsChanges: false
        )
        store.setRecordsForTesting([
            makeRecord(sessionID: "one", title: "t"),
            makeRecord(sessionID: "two", title: "t"),
        ])
        XCTAssertEqual(store.records.count, 2)

        store.setIndexingEnabled(false)
        XCTAssertTrue(store.records.isEmpty, "turning indexing off drops every indexed record")
        XCTAssertFalse(store.isIndexingEnabled)
    }

    // MARK: - Source shape

    func testInsertSendsResumeCommandWithoutNewline() throws {
        let source = try agentSessionSourceFile("Sources/KurottyApp/TerminalWindowCommandHistory.swift")
        XCTAssertTrue(
            source.contains("sendTextToActivePane(AgentSessionResumeCommand.command(for: record))"),
            "the default action must insert the resume command as-is"
        )
        XCTAssertFalse(
            source.contains("AgentSessionResumeCommand.command(for: record) + \"\\n\""),
            "the resume command must never be sent with a trailing newline"
        )
    }

    func testNoExecutePathExistsForAgentSessions() throws {
        let panelSource = try agentSessionSourceFile("Sources/KurottyApp/TerminalAgentSessionPanelView.swift")
        let integrationSource = try agentSessionSourceFile("Sources/KurottyApp/TerminalWindowCommandHistory.swift")
        XCTAssertFalse(panelSource.contains("onRunSession"), "v1 has no run action on the panel")
        XCTAssertFalse(
            panelSource.contains("TerminalCommandDispatcher"),
            "agent sessions must not route through the replay dispatcher at all"
        )
        for symbol in ["runAgentSession", "executeAgentSession", "TerminalCommandReplayApproval(isExplicitlyConfirmed: true)"] {
            XCTAssertFalse(
                integrationSource.contains(symbol + "(record"),
                "no agent-session execute path may exist: found \(symbol)"
            )
        }
        XCTAssertFalse(
            integrationSource.contains("AgentSessionReplay"),
            "agent sessions must not gain a replay candidate path"
        )
    }

    func testTogglePanelCommandIsRegisteredWithoutShortcutConflicts() throws {
        let commands = TerminalCommandRegistry.default.windowCommands
        let toggleCommand = try XCTUnwrap(commands.first { $0.id == .toggleAgentSessionPanel })
        XCTAssertEqual(toggleCommand.id.rawValue, "sessions.togglePanel")
        XCTAssertEqual(toggleCommand.shortcut?.keyEquivalent, "a")
        XCTAssertEqual(
            commands.filter { $0.shortcut?.keyEquivalent == "a" }.count,
            1,
            "Cmd+Shift+A must stay unique to the agent-session panel toggle"
        )
    }

    func testDispatcherAndMenuExposeTheAgentSessionToggle() throws {
        let dispatcherSource = try agentSessionSourceFile("Sources/KurottyApp/TerminalCommandDispatcher.swift")
        XCTAssertTrue(dispatcherSource.contains("case .toggleAgentSessionPanel:"))
        XCTAssertTrue(dispatcherSource.contains("controller.toggleAgentSessionPanel()"))

        let menuSource = try agentSessionSourceFile("Sources/KurottyApp/MainMenu.swift")
        XCTAssertTrue(menuSource.contains("AppDelegate.toggleAgentSessionPanel"))
        XCTAssertTrue(menuSource.contains("keyEquivalent: \"A\""))
    }

    func testDebugFlagOpensThePanelOnTheAgentSessionSection() throws {
        let debugSource = try agentSessionSourceFile("Sources/KurottyApp/DebugOptions.swift")
        XCTAssertTrue(debugSource.contains("--debug-show-agent-sessions"))
        XCTAssertTrue(debugSource.contains("KUROTTY_DEBUG_SHOW_AGENT_SESSIONS"))

        let delegateSource = try agentSessionSourceFile("Sources/KurottyApp/AppDelegate.swift")
        XCTAssertTrue(
            delegateSource.contains("setCommandHistoryPanelVisible(true, section: .agentSessions)"),
            "the debug flag must reuse setCommandHistoryPanelVisible"
        )
    }

    func testStoreNeverPersistsIndexedRecords() throws {
        let storeSource = try agentSessionSourceFile("Sources/KurottyApp/AgentSessionIndexStore.swift")
        for writeSymbol in ["data.write(", "createDirectory(", "JSONEncoder("] {
            XCTAssertFalse(storeSource.contains(writeSymbol), "the index must stay in memory: found \(writeSymbol)")
        }
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
    func testAgentSessionSectionShowsAndTogglesTheLeftPanel() {
        let controller = makeWindowController()
        // Leaked controllers keep observing global notifications and
        // destabilize unrelated suites, so close deterministically.
        defer { controller.close() }

        XCTAssertFalse(controller.isCommandHistoryPanelVisible)
        XCTAssertEqual(controller.selectedLeftSidebarSection, .commandHistory)

        controller.toggleAgentSessionPanel()
        XCTAssertTrue(controller.isCommandHistoryPanelVisible)
        XCTAssertEqual(controller.selectedLeftSidebarSection, .agentSessions)

        controller.toggleAgentSessionPanel()
        XCTAssertFalse(controller.isCommandHistoryPanelVisible)
    }

    @MainActor
    func testAgentSessionToggleSwitchesSectionInsteadOfClosingHistory() {
        let controller = makeWindowController()
        defer { controller.close() }

        controller.toggleCommandHistoryPanel()
        XCTAssertEqual(controller.selectedLeftSidebarSection, .commandHistory)

        controller.toggleAgentSessionPanel()
        XCTAssertTrue(controller.isCommandHistoryPanelVisible)
        XCTAssertEqual(controller.selectedLeftSidebarSection, .agentSessions)
    }

    /// Regression: a hidden arranged subview still participates in Auto
    /// Layout, so leaving the width constraints active kept the split view
    /// reserving a strip of width plus its divider after closing a sidebar.
    @MainActor
    func testAHiddenSidebarReservesNoWidth() {
        // Width used to be a constraint that was toggled with visibility. It is
        // a divider position now, and hiding takes the panel out of the split
        // view entirely, so the contract is asserted through geometry instead
        // of through the constraints that no longer exist.
        let controller = makeWindowController()
        defer { controller.close() }
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let split = controller.commandHistorySplitView
        XCTAssertFalse(split.arrangedSubviews.contains(controller.leftSidebarPanel))
        XCTAssertFalse(split.arrangedSubviews.contains(controller.fileExplorerPanel))
        XCTAssertEqual(
            controller.terminalContentHostView.frame.width,
            split.frame.width,
            accuracy: 1,
            "with both sidebars hidden the terminal must own the whole width"
        )

        controller.setCommandHistoryPanelVisible(true)
        controller.setFileExplorerPanelVisible(true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(split.arrangedSubviews.contains(controller.leftSidebarPanel))
        XCTAssertTrue(split.arrangedSubviews.contains(controller.fileExplorerPanel))
        XCTAssertLessThan(controller.terminalContentHostView.frame.width, split.frame.width)

        controller.setCommandHistoryPanelVisible(false)
        controller.setFileExplorerPanelVisible(false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            controller.terminalContentHostView.frame.width,
            split.frame.width,
            accuracy: 1,
            "hiding both sidebars must give the width back"
        )
    }

    func testBothSidebarsRouteThroughTheSharedHiddenHelper() throws {
        let historySource = try agentSessionSourceFile("Sources/KurottyApp/TerminalWindowCommandHistory.swift")
        let explorerSource = try agentSessionSourceFile("Sources/KurottyApp/TerminalWindowFileExplorer.swift")
        for source in [historySource, explorerSource] {
            XCTAssertTrue(
                source.contains("setSidebarPanelHidden("),
                "both sidebars must collapse through the shared helper"
            )
        }
        XCTAssertFalse(historySource.contains("leftSidebarPanel.isHidden = !visible"))
        XCTAssertFalse(explorerSource.contains("fileExplorerPanel.isHidden = !visible"))
    }

    /// Regression: the section selector's required trailing pin let its
    /// intrinsic label width push the sidebar past its maximum width, which
    /// made the panel grow on every layout pass.
    @MainActor
    func testSectionSelectorCannotWidenTheSidebarPastItsMaximum() {
        let panel = TerminalLeftSidebarPanelView()
        panel.frame = NSRect(
            x: 0,
            y: 0,
            width: DesignTokens.Component.commandHistoryPanelDefaultWidthPX,
            height: 600
        )
        panel.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            panel.fittingSize.width,
            DesignTokens.Component.commandHistoryPanelMaxWidthPX,
            "the left sidebar must never demand more than its maximum width"
        )
    }

    @MainActor
    func testDisabledIndexShowsTheExplanatoryEmptyState() {
        let store = AgentSessionIndexStore(
            homeDirectory: URL(fileURLWithPath: "/nonexistent-home-for-tests"),
            scanners: [],
            isIndexingEnabled: false,
            observesSettingsChanges: false
        )
        let panel = TerminalAgentSessionPanelView(store: store, homeDirectory: Fixture.homeDirectory)
        XCTAssertTrue(panel.visibleGroupsForTesting.isEmpty)
        XCTAssertEqual(
            panel.emptyStateTextForTesting,
            AppLocalization.string(.agentSessionsDisabledExplanation)
        )
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurotty-agent-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ansiJSONArray() -> String {
        let colors = TerminalColorSettings.default.ansi
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        return "[\(colors)]"
    }
}

/// Scanner that fails the test if a disabled store ever walks the filesystem.
private struct FailingScanner: AgentSessionScanning {
    let agent = AgentSessionKind.claudeCode

    func rootURL(homeDirectory: URL) -> URL {
        homeDirectory
    }

    func sessionFileURLs(rootURL: URL, fileManager: FileManager) -> [URL] {
        XCTFail("a disabled agent-session index must never walk the filesystem")
        return []
    }

    func parse(
        contents: String,
        fileURL: URL,
        modifiedAt: Date,
        isTranscriptTruncated: Bool
    ) -> AgentSessionRecord? {
        XCTFail("a disabled agent-session index must never parse transcripts")
        return nil
    }
}

private func agentSessionSourceFile(_ relativePath: String) throws -> String {
    try String(
        contentsOf: agentSessionSourceRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

private func agentSessionSourceRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 {
        url.deleteLastPathComponent()
    }
    return url
}
