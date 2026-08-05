import Foundation
import XCTest
@testable import KurottyApp

/// Fixtures copied from the record shapes the two agents actually write.
///
/// Claude records a write as a `tool_use` block inside an `assistant` record and
/// reports the outcome later as a `tool_result`. Codex has no edit tool at all:
/// it patches files and reports an `event_msg` / `patch_apply_end` whose
/// `changes` map is keyed by absolute path. Treating either shape as the other
/// finds nothing, which is why both are pinned here.
private enum Fixture {
    static let sessionID = "11111111-2222-3333-4444-555555555555"
    static let transcriptPath = "/Users/tester/.claude/projects/slug/\(sessionID).jsonl"
    static let codexTranscriptPath =
        "/Users/tester/.codex/sessions/2026/08/01/rollout-2026-08-01T10-00-00-\(sessionID).jsonl"
    static let projectRoot = "/Users/tester/dev/project"
    static let greetingPath = "\(projectRoot)/Sources/App/Greeting.swift"
    static let readmePath = "\(projectRoot)/README.md"
    static let firstPrompt = "Rename the greeting helper"
    static let secondPrompt = "Now update the README to match"

    static func transcript(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    static func claudeUserPrompt(_ text: String, at timestamp: String) -> String {
        """
        {"type":"user","sessionId":"\(sessionID)","cwd":"\(projectRoot)","timestamp":"\(timestamp)",\
        "message":{"role":"user","content":"\(text)"}}
        """
    }

    static func claudeToolUse(
        identifier: String,
        name: String,
        inputJSON: String,
        at timestamp: String
    ) -> String {
        """
        {"type":"assistant","sessionId":"\(sessionID)","cwd":"\(projectRoot)","timestamp":"\(timestamp)",\
        "message":{"role":"assistant","content":[{"type":"tool_use","id":"\(identifier)",\
        "name":"\(name)","input":\(inputJSON)}]}}
        """
    }

    static func claudeToolResult(
        identifier: String,
        isError: Bool,
        at timestamp: String
    ) -> String {
        """
        {"type":"user","sessionId":"\(sessionID)","timestamp":"\(timestamp)",\
        "message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(identifier)",\
        "is_error":\(isError),"content":"result"}]}}
        """
    }

    static func codexUserMessage(_ text: String, at timestamp: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg",\
        "payload":{"type":"user_message","message":"\(text)","images":[]}}
        """
    }

    static func codexPatchApplyEnd(
        changesJSON: String,
        success: Bool,
        at timestamp: String
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"patch_apply_end",\
        "call_id":"call_1","turn_id":"turn_1","stdout":"Success.","stderr":"",\
        "success":\(success),"changes":\(changesJSON),"status":"completed"}}
        """
    }

    static func change(type: String) -> String {
        #"{"type":"\#(type)","unified_diff":"@@ -1 +1 @@\n-a\n+b\n","move_path":null}"#
    }

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }
}

// MARK: - Claude

final class ClaudeFileProvenanceExtractorTests: XCTestCase {
    private let extractor = ClaudeFileProvenanceExtractor()

    private func touches(_ lines: [String]) -> [AgentFileTouch] {
        extractor.touches(
            contents: Fixture.transcript(lines),
            sessionID: Fixture.sessionID,
            transcriptPath: Fixture.transcriptPath
        )
    }

    func testEditWriteAndMultiEditToolCallsBecomeTouches() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_edit",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)","old_string":"a","new_string":"b"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeToolUse(
                identifier: "tu_write",
                name: "Write",
                inputJSON: #"{"file_path":"\#(Fixture.readmePath)","content":"Project readme"}"#,
                at: "2026-08-01T10:00:06.000Z"
            ),
            Fixture.claudeToolUse(
                identifier: "tu_multi",
                name: "MultiEdit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)","edits":[]}"#,
                at: "2026-08-01T10:00:07.000Z"
            ),
        ])
        XCTAssertEqual(result.map(\.absolutePath), [
            Fixture.greetingPath,
            Fixture.readmePath,
            Fixture.greetingPath,
        ])
        XCTAssertEqual(result.map(\.kind), [.edited, .replaced, .edited])
        XCTAssertEqual(result.map(\.agent), [.claudeCode, .claudeCode, .claudeCode])
        XCTAssertEqual(Set(result.map(\.sessionID)), [Fixture.sessionID])
        XCTAssertEqual(Set(result.map(\.transcriptPath)), [Fixture.transcriptPath])
        XCTAssertEqual(result.first?.changedAt, Fixture.date("2026-08-01T10:00:05.000Z"))
    }

    func testTheMostRecentUserPromptIsAttributedToEachWrite() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_1",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeUserPrompt(Fixture.secondPrompt, at: "2026-08-01T10:01:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_2",
                name: "Write",
                inputJSON: #"{"file_path":"\#(Fixture.readmePath)","content":"x"}"#,
                at: "2026-08-01T10:01:05.000Z"
            ),
        ])
        XCTAssertEqual(result.map(\.promptExcerpt), [Fixture.firstPrompt, Fixture.secondPrompt])
    }

    /// A user record carrying only tool results is the transcript's way of
    /// returning output, not a new instruction. Letting it clear the prompt
    /// would leave every write after the first one unattributed.
    func testToolResultOnlyUserTurnDoesNotReplaceThePrompt() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_1",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeToolResult(identifier: "tu_1", isError: false, at: "2026-08-01T10:00:06.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_2",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.readmePath)"}"#,
                at: "2026-08-01T10:00:07.000Z"
            ),
        ])
        XCTAssertEqual(result.map(\.promptExcerpt), [Fixture.firstPrompt, Fixture.firstPrompt])
    }

    func testInjectedUserTurnsDoNotReplaceThePrompt() {
        let injected = """
        {"type":"user","isMeta":true,"timestamp":"2026-08-01T10:00:06.000Z",\
        "message":{"role":"user","content":"<system-reminder>ignore me</system-reminder>"}}
        """
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            injected,
            Fixture.claudeToolUse(
                identifier: "tu_1",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
                at: "2026-08-01T10:00:07.000Z"
            ),
        ])
        XCTAssertEqual(result.map(\.promptExcerpt), [Fixture.firstPrompt])
    }

    /// An `is_error` tool result means the edit never reached the file, so
    /// reporting it would attribute a change that does not exist.
    func testFailedEditIsNotReportedAsAChange() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_bad",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeToolResult(identifier: "tu_bad", isError: true, at: "2026-08-01T10:00:06.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_good",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.readmePath)"}"#,
                at: "2026-08-01T10:00:07.000Z"
            ),
            Fixture.claudeToolResult(identifier: "tu_good", isError: false, at: "2026-08-01T10:00:08.000Z"),
        ])
        XCTAssertEqual(result.map(\.absolutePath), [Fixture.readmePath])
    }

    func testRelativeAndMissingPathsAreDropped() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_rel",
                name: "Edit",
                inputJSON: #"{"file_path":"Sources/App/Greeting.swift"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeToolUse(
                identifier: "tu_none",
                name: "Write",
                inputJSON: #"{"content":"orphan"}"#,
                at: "2026-08-01T10:00:06.000Z"
            ),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testDotSegmentsAreStandardizedSoOneFileIsNotTwo() {
        let result = touches([
            Fixture.claudeToolUse(
                identifier: "tu_1",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.projectRoot)/Sources/App/../App/Greeting.swift"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
        ])
        XCTAssertEqual(result.map(\.absolutePath), [Fixture.greetingPath])
    }

    func testReadOnlyToolsAndEmptyTranscriptsProduceNoTouches() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_read",
                name: "Read",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeToolUse(
                identifier: "tu_bash",
                name: "Bash",
                inputJSON: #"{"command":"ls"}"#,
                at: "2026-08-01T10:00:06.000Z"
            ),
        ])
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(touches([]).isEmpty)
        XCTAssertTrue(touches(["not json", "{broken"]).isEmpty)
    }

    func testSameFileWrittenTwiceInOneSessionKeepsBothWrites() {
        let result = touches([
            Fixture.claudeUserPrompt(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_1",
                name: "Write",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)","content":"first"}"#,
                at: "2026-08-01T10:00:05.000Z"
            ),
            Fixture.claudeUserPrompt(Fixture.secondPrompt, at: "2026-08-01T10:05:00.000Z"),
            Fixture.claudeToolUse(
                identifier: "tu_2",
                name: "Edit",
                inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
                at: "2026-08-01T10:05:05.000Z"
            ),
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.absolutePath)), [Fixture.greetingPath])
        XCTAssertEqual(result.map(\.kind), [.replaced, .edited])
        XCTAssertEqual(result.map(\.promptExcerpt), [Fixture.firstPrompt, Fixture.secondPrompt])

        // The index keeps both, newest first, so "who changed this and why" has
        // history rather than only a latest value.
        let index = AgentFileProvenanceIndex(touches: result)
        let history = index.provenance(forAbsolutePath: Fixture.greetingPath)
        XCTAssertEqual(history.map(\.promptExcerpt), [Fixture.secondPrompt, Fixture.firstPrompt])
        XCTAssertEqual(index.mostRecentTouch(forAbsolutePath: Fixture.greetingPath)?.kind, .edited)
    }
}

// MARK: - Codex

final class CodexFileProvenanceExtractorTests: XCTestCase {
    private let extractor = CodexFileProvenanceExtractor()

    private func touches(_ lines: [String]) -> [AgentFileTouch] {
        extractor.touches(
            contents: Fixture.transcript(lines),
            sessionID: Fixture.sessionID,
            transcriptPath: Fixture.codexTranscriptPath
        )
    }

    func testPatchApplyEndChangesBecomeTouchesWithTheirChangeKinds() {
        let changes = """
        {"\(Fixture.greetingPath)":\(Fixture.change(type: "update")),\
        "\(Fixture.readmePath)":\(Fixture.change(type: "add"))}
        """
        let result = touches([
            Fixture.codexUserMessage(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.codexPatchApplyEnd(
                changesJSON: changes,
                success: true,
                at: "2026-08-01T10:00:05.000Z"
            ),
        ])
        // One patch touches several files; ordering is by path because JSON
        // object member order carries no meaning.
        XCTAssertEqual(result.map(\.absolutePath), [Fixture.readmePath, Fixture.greetingPath])
        XCTAssertEqual(result.map(\.kind), [.replaced, .edited])
        XCTAssertEqual(Set(result.map(\.agent)), [.codex])
        XCTAssertEqual(Set(result.map(\.promptExcerpt)), [Fixture.firstPrompt])
        XCTAssertEqual(result.first?.changedAt, Fixture.date("2026-08-01T10:00:05.000Z"))
    }

    func testDeletionsAreRecordedAsDeletions() {
        let changes = #"{"\#(Fixture.readmePath)":\#(Fixture.change(type: "delete"))}"#
        let result = touches([
            Fixture.codexPatchApplyEnd(
                changesJSON: changes,
                success: true,
                at: "2026-08-01T10:00:05.000Z"
            ),
        ])
        XCTAssertEqual(result.map(\.kind), [.deleted])
    }

    /// `success: false` means the patch was rejected, so nothing on disk moved.
    func testUnsuccessfulPatchIsNotReported() {
        let changes = #"{"\#(Fixture.greetingPath)":\#(Fixture.change(type: "update"))}"#
        let result = touches([
            Fixture.codexUserMessage(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.codexPatchApplyEnd(
                changesJSON: changes,
                success: false,
                at: "2026-08-01T10:00:05.000Z"
            ),
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testTheMostRecentUserMessageIsAttributedToEachPatch() {
        let first = #"{"\#(Fixture.greetingPath)":\#(Fixture.change(type: "update"))}"#
        let second = #"{"\#(Fixture.readmePath)":\#(Fixture.change(type: "update"))}"#
        let result = touches([
            Fixture.codexUserMessage(Fixture.firstPrompt, at: "2026-08-01T10:00:00.000Z"),
            Fixture.codexPatchApplyEnd(changesJSON: first, success: true, at: "2026-08-01T10:00:05.000Z"),
            Fixture.codexUserMessage(Fixture.secondPrompt, at: "2026-08-01T10:01:00.000Z"),
            Fixture.codexPatchApplyEnd(changesJSON: second, success: true, at: "2026-08-01T10:01:05.000Z"),
        ])
        XCTAssertEqual(result.map(\.promptExcerpt), [Fixture.firstPrompt, Fixture.secondPrompt])
    }

    /// A bounded head/tail read can start mid-session. The write is still real;
    /// only the prompt behind it is missing.
    func testAPatchBeforeAnyPromptStillReportsTheWrite() {
        let changes = #"{"\#(Fixture.greetingPath)":\#(Fixture.change(type: "update"))}"#
        let result = touches([
            Fixture.codexPatchApplyEnd(changesJSON: changes, success: true, at: "2026-08-01T10:00:05.000Z"),
        ])
        XCTAssertEqual(result.map(\.absolutePath), [Fixture.greetingPath])
        XCTAssertNil(result.first?.promptExcerpt)
    }

    /// Codex spends most of its transcript on `exec_command` shell calls; none
    /// of those are file writes, and reading them as writes would attribute the
    /// entire repository to the agent.
    func testShellCommandsAndOtherEventsProduceNoTouches() {
        let execCall = """
        {"timestamp":"2026-08-01T10:00:05.000Z","type":"response_item",\
        "payload":{"type":"function_call","name":"exec_command","call_id":"call_2",\
        "arguments":"{\\"cmd\\":\\"rm -rf build\\",\\"workdir\\":\\"\(Fixture.projectRoot)\\"}"}}
        """
        let tokenCount = """
        {"timestamp":"2026-08-01T10:00:06.000Z","type":"event_msg",\
        "payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10}}}}
        """
        XCTAssertTrue(touches([execCall, tokenCount]).isEmpty)
    }

    /// The Claude extractor must not find Codex writes and vice versa: their
    /// record shapes have no overlap, and a silent zero would look like "this
    /// project has no agent history".
    func testTheTwoExtractorsDoNotReadEachOthersTranscripts() {
        let codexLine = Fixture.codexPatchApplyEnd(
            changesJSON: #"{"\#(Fixture.greetingPath)":\#(Fixture.change(type: "update"))}"#,
            success: true,
            at: "2026-08-01T10:00:05.000Z"
        )
        let claudeLine = Fixture.claudeToolUse(
            identifier: "tu_1",
            name: "Edit",
            inputJSON: #"{"file_path":"\#(Fixture.greetingPath)"}"#,
            at: "2026-08-01T10:00:05.000Z"
        )
        let claudeExtractor = ClaudeFileProvenanceExtractor()
        XCTAssertTrue(
            claudeExtractor.touches(
                contents: codexLine,
                sessionID: Fixture.sessionID,
                transcriptPath: Fixture.codexTranscriptPath
            ).isEmpty
        )
        XCTAssertTrue(
            extractor.touches(
                contents: claudeLine,
                sessionID: Fixture.sessionID,
                transcriptPath: Fixture.transcriptPath
            ).isEmpty
        )
        XCTAssertEqual(
            AgentFileProvenanceExtractorFactory.extractor(for: .claudeCode).agent,
            .claudeCode
        )
        XCTAssertEqual(AgentFileProvenanceExtractorFactory.extractor(for: .codex).agent, .codex)
    }
}

// MARK: - Index

final class AgentFileProvenanceIndexTests: XCTestCase {
    private let now = Fixture.date("2026-08-01T12:00:00.000Z")

    private func touch(
        path: String,
        minutesAgo: Int,
        agent: AgentSessionKind = .claudeCode,
        prompt: String? = Fixture.firstPrompt
    ) -> AgentFileTouch {
        AgentFileTouch(
            agent: agent,
            sessionID: Fixture.sessionID,
            absolutePath: path,
            changedAt: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            kind: .edited,
            promptExcerpt: prompt,
            transcriptPath: Fixture.transcriptPath
        )
    }

    func testProvenanceForAFileIsNewestFirst() {
        let index = AgentFileProvenanceIndex(touches: [
            touch(path: Fixture.greetingPath, minutesAgo: 120),
            touch(path: Fixture.greetingPath, minutesAgo: 5),
            touch(path: Fixture.greetingPath, minutesAgo: 60),
        ])
        let history = index.provenance(for: URL(fileURLWithPath: Fixture.greetingPath))
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(
            history.map(\.changedAt),
            history.sorted { $0.changedAt > $1.changedAt }.map(\.changedAt)
        )
        XCTAssertEqual(index.touchedFileCount, 1)
        XCTAssertEqual(index.touchCount, 3)
    }

    func testAFileWithNoProvenanceReportsNothing() {
        let index = AgentFileProvenanceIndex(touches: [touch(path: Fixture.greetingPath, minutesAgo: 5)])
        XCTAssertTrue(index.provenance(forAbsolutePath: Fixture.readmePath).isEmpty)
        XCTAssertNil(index.mostRecentTouch(forAbsolutePath: Fixture.readmePath))
        XCTAssertNil(index.recentTouch(forAbsolutePath: Fixture.readmePath, now: now))
        XCTAssertFalse(index.hasRecentChange(atOrUnder: Fixture.readmePath, now: now))
        XCTAssertTrue(AgentFileProvenanceIndex.empty.isEmpty)
        XCTAssertTrue(AgentFileProvenanceIndex.empty.provenance(forAbsolutePath: Fixture.greetingPath).isEmpty)
    }

    /// A collapsed folder has to report that something under it moved, or the
    /// marker is invisible until every folder is expanded by hand.
    func testAncestorDirectoriesReportRecentChangeButCarryNoTouch() {
        let index = AgentFileProvenanceIndex(touches: [touch(path: Fixture.greetingPath, minutesAgo: 5)])
        for directory in [
            "\(Fixture.projectRoot)/Sources/App",
            "\(Fixture.projectRoot)/Sources",
            Fixture.projectRoot,
        ] {
            XCTAssertTrue(
                index.hasRecentChange(atOrUnder: directory, now: now),
                "expected \(directory) to report a recent change"
            )
            XCTAssertNil(index.mostRecentTouch(forAbsolutePath: directory))
        }
        XCTAssertFalse(
            index.hasRecentChange(atOrUnder: "\(Fixture.projectRoot)/Tests", now: now)
        )
    }

    func testTouchesOlderThanTheWindowAreNotRecent() {
        let index = AgentFileProvenanceIndex(touches: [
            touch(path: Fixture.greetingPath, minutesAgo: 25 * 60),
        ])
        XCTAssertNil(index.recentTouch(forAbsolutePath: Fixture.greetingPath, now: now))
        XCTAssertFalse(index.hasRecentChange(atOrUnder: Fixture.projectRoot, now: now))
        // Still findable as history: recency gates the marker, not the answer.
        XCTAssertEqual(index.provenance(forAbsolutePath: Fixture.greetingPath).count, 1)
    }

    func testPerFileHistoryIsCappedNewestFirst() {
        let overflow = AppConstants.AgentProvenance.maximumTouchesPerFile + 10
        let index = AgentFileProvenanceIndex(touches: (0..<overflow).map {
            touch(path: Fixture.greetingPath, minutesAgo: $0)
        })
        let history = index.provenance(forAbsolutePath: Fixture.greetingPath)
        XCTAssertEqual(history.count, AppConstants.AgentProvenance.maximumTouchesPerFile)
        // Newest survives the cap; the oldest entries are what is dropped.
        XCTAssertEqual(history.first?.changedAt, now)
    }

    func testTwoAgentsCanShareOneFile() {
        let index = AgentFileProvenanceIndex(touches: [
            touch(path: Fixture.greetingPath, minutesAgo: 30, agent: .codex),
            touch(path: Fixture.greetingPath, minutesAgo: 5, agent: .claudeCode),
        ])
        XCTAssertEqual(index.mostRecentTouch(forAbsolutePath: Fixture.greetingPath)?.agent, .claudeCode)
        XCTAssertEqual(
            index.provenance(forAbsolutePath: Fixture.greetingPath).map(\.agent),
            [.claudeCode, .codex]
        )
    }
}

// MARK: - Explorer marker and copy

final class FileExplorerAgentMarkerTests: XCTestCase {
    private let now = Fixture.date("2026-08-01T12:00:00.000Z")

    private func index(minutesAgo: Int, prompt: String? = Fixture.firstPrompt) -> AgentFileProvenanceIndex {
        AgentFileProvenanceIndex(touches: [
            AgentFileTouch(
                agent: .claudeCode,
                sessionID: Fixture.sessionID,
                absolutePath: Fixture.greetingPath,
                changedAt: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
                kind: .edited,
                promptExcerpt: prompt,
                transcriptPath: Fixture.transcriptPath
            ),
        ])
    }

    func testAFileMarkerCarriesTheTouchAndADirectoryMarkerDoesNot() {
        let provenance = index(minutesAgo: 120)
        let file = FileExplorerAgentMarker.make(
            absolutePath: Fixture.greetingPath,
            provenance: provenance,
            now: now
        )
        XCTAssertTrue(file.hasRecentChange)
        XCTAssertEqual(file.touch?.promptExcerpt, Fixture.firstPrompt)

        let directory = FileExplorerAgentMarker.make(
            absolutePath: "\(Fixture.projectRoot)/Sources",
            provenance: provenance,
            now: now
        )
        XCTAssertTrue(directory.hasRecentChange)
        XCTAssertNil(directory.touch)
    }

    func testUntouchedPathsAndStaleTouchesProduceNoMarker() {
        XCTAssertEqual(
            FileExplorerAgentMarker.make(
                absolutePath: Fixture.readmePath,
                provenance: index(minutesAgo: 5),
                now: now
            ),
            .none
        )
        XCTAssertEqual(
            FileExplorerAgentMarker.make(
                absolutePath: Fixture.greetingPath,
                provenance: index(minutesAgo: 60 * 24 * 3),
                now: now
            ),
            .none
        )
    }

    func testTooltipNamesTheAgentTheAgeAndThePrompt() throws {
        let touch = try XCTUnwrap(
            index(minutesAgo: 120).mostRecentTouch(forAbsolutePath: Fixture.greetingPath)
        )
        let tooltip = FileExplorerAgentTouchCopy.tooltip(for: touch, now: now, language: .english)
        XCTAssertTrue(tooltip.contains(AgentSessionKind.claudeCode.displayName))
        XCTAssertTrue(tooltip.contains(Fixture.firstPrompt))
        XCTAssertTrue(tooltip.contains("2h"))
    }

    func testTooltipOmitsThePromptLineWhenTheTranscriptRecordedNone() throws {
        let touch = try XCTUnwrap(
            index(minutesAgo: 10, prompt: nil).mostRecentTouch(forAbsolutePath: Fixture.greetingPath)
        )
        let tooltip = FileExplorerAgentTouchCopy.tooltip(for: touch, now: now, language: .english)
        XCTAssertFalse(tooltip.contains("\n"))
        XCTAssertTrue(tooltip.contains(AgentSessionKind.claudeCode.displayName))
    }

    func testEveryProvenanceStringIsLocalizedInAllThreeLanguages() {
        let keys: [L10nKey] = [
            .fileExplorerAgentTouchTitle,
            .fileExplorerAgentTouchPrompt,
            .fileExplorerAgentTouchAccessibility,
        ]
        for language in AppLanguage.allCases {
            for key in keys {
                XCTAssertTrue(
                    AppLocalization.hasTranslation(for: key, language: language),
                    "missing \(language.rawValue) translation for \(key.rawValue)"
                )
            }
        }
    }
}
