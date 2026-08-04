import XCTest
@testable import KurottyApp

/// Backward chunked tail reads: the viewer must open a very large transcript by
/// touching only its last chunks.
final class AgentSessionTranscriptTailReaderTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    private func write(_ contents: String, name: String = "session.jsonl") throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func record(_ index: Int) -> String {
        #"{"type":"user","uuid":"u\#(index)","message":{"role":"user","content":"line \#(index)"}}"#
    }

    func testSmallFileReadsEveryRecord() throws {
        let url = try write("alpha\nbeta\ngamma\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10)

        XCTAssertEqual(result.lines.map(\.text), ["alpha", "beta", "gamma"])
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.consumedTo, 17)
    }

    func testByteOffsetsPointAtRecordStarts() throws {
        let url = try write("alpha\nbeta\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10)

        XCTAssertEqual(result.lines.map(\.byteOffset), [0, 6])
    }

    func testFileSmallerThanChunkWindowStillReads() throws {
        let url = try write("only\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 5, chunkBytes: 64 * 1024)

        XCTAssertEqual(result.lines.map(\.text), ["only"])
    }

    func testLimitKeepsNewestRecordsAndReportsMore() throws {
        let url = try write((1...10).map { "line \($0)" }.joined(separator: "\n") + "\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 3)

        XCTAssertEqual(result.lines.map(\.text), ["line 8", "line 9", "line 10"])
        XCTAssertTrue(result.hasMore)
    }

    func testRecordSpanningChunkBoundaryIsReassembled() throws {
        // Each record is wider than the chunk, so every read straddles a
        // boundary and the parts must be joined in the right order.
        let long = String(repeating: "x", count: 50)
        let url = try write("\(long)A\n\(long)B\n\(long)C\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10, chunkBytes: 8)

        XCTAssertEqual(result.lines.map(\.text), ["\(long)A", "\(long)B", "\(long)C"])
    }

    func testChunkBoundaryLandingExactlyOnNewline() throws {
        // "abc\ndef\n": a chunk size of 4 makes every read end on a newline.
        let url = try write("abc\ndef\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10, chunkBytes: 4)

        XCTAssertEqual(result.lines.map(\.text), ["abc", "def"])
    }

    func testTrailingPartialRecordIsExcluded() throws {
        // A write in flight leaves the last record without its newline.
        let url = try write("complete\npartial-in-flight")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10)

        XCTAssertEqual(result.lines.map(\.text), ["complete"])
        XCTAssertEqual(result.consumedTo, 9)
    }

    func testFileWithoutAnyNewlineYieldsNothing() throws {
        let url = try write("no-newline-at-all")

        XCTAssertEqual(AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10), .empty)
    }

    func testEmptyFileYieldsEmptyResult() throws {
        let url = try write("")

        XCTAssertEqual(AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10), .empty)
    }

    func testMissingFileYieldsEmptyResult() {
        let url = directoryURL.appendingPathComponent("absent.jsonl")

        XCTAssertEqual(AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10), .empty)
    }

    func testOversizedRecordIsDroppedWithoutLosingNeighbours() throws {
        let huge = String(repeating: "z", count: 512)
        let url = try write("before\n\(huge)\nafter\n")

        let result = AgentSessionTranscriptTailReader.readTail(
            fileURL: url,
            limit: 10,
            maximumRecordBytes: 128
        )

        XCTAssertEqual(result.lines.map(\.text), ["before", "after"])
        XCTAssertEqual(result.oversizedRecordCount, 1)
    }

    func testCarriageReturnLineEndingsAreStripped() throws {
        let url = try write("alpha\r\nbeta\r\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 10)

        XCTAssertEqual(result.lines.map(\.text), ["alpha", "beta"])
    }

    func testTailOfLargeFileTouchesOnlyTrailingRecords() throws {
        let url = try write((1...5_000).map(record).joined(separator: "\n") + "\n")

        let result = AgentSessionTranscriptTailReader.readTail(fileURL: url, limit: 5)

        XCTAssertEqual(result.lines.count, 5)
        XCTAssertTrue(try XCTUnwrap(result.lines.last).text.contains("\"u5000\""))
        XCTAssertTrue(result.hasMore)
    }
}

final class AgentSessionTranscriptIncrementalReaderTests: XCTestCase {
    private var directoryURL: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-transcript-append-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("session.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    private func append(_ text: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try Data(text.utf8).write(to: fileURL)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testReadsOnlyNewlyAppendedRecords() throws {
        try append("first\n")
        var reader = AgentSessionTranscriptIncrementalReader()

        XCTAssertEqual(reader.readAppendedLines(fileURL: fileURL).map(\.text), ["first"])
        XCTAssertEqual(reader.readAppendedLines(fileURL: fileURL), [])

        try append("second\n")
        XCTAssertEqual(reader.readAppendedLines(fileURL: fileURL).map(\.text), ["second"])
    }

    func testPartialRecordIsBufferedUntilItsNewlineArrives() throws {
        try append("complete\npar")
        var reader = AgentSessionTranscriptIncrementalReader()

        XCTAssertEqual(reader.readAppendedLines(fileURL: fileURL).map(\.text), ["complete"])

        try append("tial\n")
        let completed = reader.readAppendedLines(fileURL: fileURL)

        XCTAssertEqual(completed.map(\.text), ["partial"])
        XCTAssertEqual(completed.map(\.byteOffset), [9])
    }

    func testStartingOffsetSkipsAlreadyPaintedTail() throws {
        try append("old\nnew\n")
        var reader = AgentSessionTranscriptIncrementalReader(offset: 4)

        XCTAssertEqual(reader.readAppendedLines(fileURL: fileURL).map(\.text), ["new"])
    }

    func testShrunkFileResetsStateSoTheTailIsRepainted() throws {
        try append("aaaa\nbbbb\n")
        var reader = AgentSessionTranscriptIncrementalReader()
        _ = reader.readAppendedLines(fileURL: fileURL)
        XCTAssertEqual(reader.offset, 10)

        XCTAssertTrue(reader.resetIfFileShrank(fileSizeBytes: 4))
        XCTAssertEqual(reader.offset, 0)
        XCTAssertFalse(reader.resetIfFileShrank(fileSizeBytes: 10))
    }

    func testOversizedAppendedRecordIsDropped() throws {
        try append("small\n")
        var reader = AgentSessionTranscriptIncrementalReader(maximumRecordBytes: 16)
        _ = reader.readAppendedLines(fileURL: fileURL)

        try append(String(repeating: "y", count: 64) + "\nnext\n")
        let lines = reader.readAppendedLines(fileURL: fileURL)

        XCTAssertEqual(lines.map(\.text), ["next"])
        XCTAssertEqual(reader.oversizedRecordCount, 1)
    }
}

final class ClaudeTranscriptDecoderTests: XCTestCase {
    private let decoder = ClaudeTranscriptDecoder()

    private func decode(_ line: String) -> AgentTranscriptMessage? {
        decoder.decode(line: line, fallbackID: "fallback", byteOffset: 0)
    }

    func testUserRecordWithStringContent() throws {
        let message = try XCTUnwrap(decode(
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}"#
        ))

        XCTAssertEqual(message.id, "u1")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.blocks, [.text("hello")])
    }

    func testAssistantRecordWithArrayContent() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"assistant","uuid":"a1","message":{"content":[\
        {"type":"text","text":"sure"},{"type":"thinking","thinking":"considering"}]}}
        """))

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.blocks, [.text("sure"), .text("considering")])
    }

    func testToolUseBlockCarriesNamePreviewAndDetail() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"assistant","uuid":"a2","message":{"content":[\
        {"type":"tool_use","name":"Read","input":{"file_path":"/tmp/foo.swift"}}]}}
        """))

        guard case let .toolCall(call) = try XCTUnwrap(message.blocks.first) else {
            return XCTFail("expected a tool call block")
        }
        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.preview, "/tmp/foo.swift")
        XCTAssertTrue(call.detail.contains("file_path"))
        XCTAssertNil(call.diff)
    }

    func testToolResultRecordBecomesToolRole() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"user","uuid":"u2","message":{"content":[\
        {"type":"tool_result","content":"ok","is_error":false}]}}
        """))

        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.blocks, [.toolResult(AgentTranscriptToolResult(output: "ok"))])
    }

    func testToolResultWithArrayContentIsFlattened() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"user","uuid":"u3","message":{"content":[\
        {"type":"tool_result","content":[{"type":"text","text":"one"},{"type":"text","text":"two"}],\
        "is_error":true}]}}
        """))

        XCTAssertEqual(
            message.blocks,
            [.toolResult(AgentTranscriptToolResult(output: "one\ntwo", isError: true))]
        )
    }

    func testInjectedUserTurnKeepsOnlyItsToolResults() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"user","uuid":"u4","isMeta":true,"message":{"content":[\
        {"type":"text","text":"injected machinery"},{"type":"tool_result","content":"real"}]}}
        """))

        XCTAssertEqual(message.blocks, [.toolResult(AgentTranscriptToolResult(output: "real"))])
    }

    func testInjectedUserTurnWithNoToolResultIsDropped() {
        XCTAssertNil(decode("""
        {"type":"user","uuid":"u5","isSynthetic":true,"message":{"content":[\
        {"type":"text","text":"injected"}]}}
        """))
    }

    func testUnknownRecordTypesAndMalformedLinesDecodeToNil() {
        XCTAssertNil(decode(#"{"type":"summary","summary":"x"}"#))
        XCTAssertNil(decode("not json at all"))
        XCTAssertNil(decode(""))
        XCTAssertNil(decode(#"{"type":"user","message":{"content":[]}}"#))
    }

    func testMissingUuidFallsBackToOffsetIdentity() throws {
        let message = try XCTUnwrap(decoder.decode(
            line: #"{"type":"user","message":{"content":"hi"}}"#,
            fallbackID: AgentTranscriptFallbackID.make(filePath: "/tmp/a.jsonl", byteOffset: 42),
            byteOffset: 42
        ))

        XCTAssertEqual(message.id, "/tmp/a.jsonl#42")
        XCTAssertEqual(message.byteOffset, 42)
    }

    func testTimestampIsParsedWithAndWithoutFractionalSeconds() throws {
        let plain = try XCTUnwrap(decode(
            #"{"type":"user","uuid":"t1","timestamp":"2026-08-05T10:00:00Z","message":{"content":"a"}}"#
        ))
        let fractional = try XCTUnwrap(decode(
            #"{"type":"user","uuid":"t2","timestamp":"2026-08-05T10:00:00.500Z","message":{"content":"a"}}"#
        ))

        XCTAssertNotNil(plain.timestamp)
        XCTAssertNotNil(fractional.timestamp)
        XCTAssertEqual(
            try XCTUnwrap(fractional.timestamp).timeIntervalSince(try XCTUnwrap(plain.timestamp)),
            0.5,
            accuracy: 0.001
        )
    }
}

final class CodexTranscriptDecoderTests: XCTestCase {
    private let decoder = CodexTranscriptDecoder()

    private func decode(_ line: String) -> AgentTranscriptMessage? {
        decoder.decode(line: line, fallbackID: "fallback", byteOffset: 0)
    }

    func testTypedUserMessageDecodes() throws {
        let message = try XCTUnwrap(decode(
            #"{"type":"event_msg","payload":{"type":"user_message","message":"do the thing"}}"#
        ))

        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.blocks, [.text("do the thing")])
    }

    func testAssistantResponseItemDecodes() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"response_item","payload":{"type":"message","role":"assistant",\
        "content":[{"type":"text","text":"done"}]}}
        """))

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.blocks, [.text("done")])
    }

    func testFunctionCallDecodesArgumentsFromEmbeddedJsonString() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"response_item","payload":{"type":"function_call","name":"shell",\
        "call_id":"c1","arguments":"{\\"command\\":\\"ls -al\\"}"}}
        """))

        guard case let .toolCall(call) = try XCTUnwrap(message.blocks.first) else {
            return XCTFail("expected a tool call block")
        }
        XCTAssertEqual(message.id, "c1")
        XCTAssertEqual(call.name, "shell")
        XCTAssertEqual(call.preview, "ls -al")
    }

    func testFunctionCallOutputDecodesAsToolRole() throws {
        let message = try XCTUnwrap(decode("""
        {"type":"response_item","payload":{"type":"function_call_output","call_id":"c1",\
        "output":"total 0"}}
        """))

        XCTAssertEqual(message.role, .tool)
        XCTAssertEqual(message.blocks, [.toolResult(AgentTranscriptToolResult(output: "total 0"))])
    }

    func testUnrelatedRecordsDecodeToNil() {
        XCTAssertNil(decode(#"{"type":"session_meta","payload":{"type":"session_meta"}}"#))
        XCTAssertNil(decode(#"{"type":"response_item"}"#))
    }
}

final class AgentTranscriptToolPresentationTests: XCTestCase {
    func testEditInputSynthesizesRemovedThenAddedLines() throws {
        let call = AgentTranscriptToolPresentation.toolCall(
            name: "Edit",
            input: [
                "file_path": "/tmp/foo.swift",
                "old_string": "let a = 1",
                "new_string": "let a = 2\nlet b = 3",
            ]
        )

        let diff = try XCTUnwrap(call.diff)
        XCTAssertEqual(diff.filePath, "/tmp/foo.swift")
        XCTAssertEqual(diff.lines, [
            .init(kind: .removed, text: "let a = 1"),
            .init(kind: .added, text: "let a = 2"),
            .init(kind: .added, text: "let b = 3"),
        ])
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.addedCount, 2)
    }

    func testWriteInputIsAllAddedLines() throws {
        let call = AgentTranscriptToolPresentation.toolCall(
            name: "Write",
            input: ["file_path": "/tmp/new.txt", "content": "one\ntwo"]
        )

        let diff = try XCTUnwrap(call.diff)
        XCTAssertEqual(diff.lines.map(\.kind), [.added, .added])
        XCTAssertEqual(diff.lines.map(\.text), ["one", "two"])
    }

    func testMultiEditMergesEveryEdit() throws {
        let call = AgentTranscriptToolPresentation.toolCall(
            name: "MultiEdit",
            input: [
                "file_path": "/tmp/foo.swift",
                "edits": [
                    ["old_string": "a", "new_string": "b"],
                    ["old_string": "c", "new_string": "d"],
                ],
            ]
        )

        XCTAssertEqual(try XCTUnwrap(call.diff).lines.map(\.text), ["a", "b", "c", "d"])
    }

    func testNonEditToolsGetNoDiff() {
        let call = AgentTranscriptToolPresentation.toolCall(
            name: "Bash",
            input: ["command": "ls -al"]
        )

        XCTAssertNil(call.diff)
        XCTAssertEqual(call.preview, "ls -al")
    }

    func testPreviewCollapsesToTheFirstLineAndTruncates() {
        let long = String(repeating: "x", count: 400)
        let call = AgentTranscriptToolPresentation.toolCall(
            name: "Bash",
            input: ["command": "\(long)\nsecond line"]
        )

        XCTAssertFalse(call.preview.contains("second line"))
        XCTAssertTrue(call.preview.hasSuffix("…"))
        XCTAssertEqual(
            call.preview.count,
            AgentTranscriptToolPresentation.maximumPreviewCharacters + 1
        )
    }
}

final class AgentTranscriptNoiseTests: XCTestCase {
    private func userMessage(_ text: String) -> AgentTranscriptMessage {
        AgentTranscriptMessage(id: "m", role: .user, blocks: [.text(text)])
    }

    func testKnownHarnessTagsAreNoise() {
        for tag in ["system-reminder", "command-name", "local-command-stdout", "task-notification"] {
            XCTAssertTrue(
                AgentTranscriptNoise.isNoise(userMessage("<\(tag)>payload</\(tag)>")),
                "expected <\(tag)> to be filtered"
            )
        }
    }

    func testKnownHarnessPrefixesAreNoise() {
        XCTAssertTrue(AgentTranscriptNoise.isNoise(userMessage("[Request interrupted by user]")))
        XCTAssertTrue(AgentTranscriptNoise.isNoise(userMessage(
            "Caveat: The messages below were generated by the user while running local commands."
        )))
    }

    func testUnknownTagsStayRealUserTurns() {
        // A genuine prompt can start with the user's own markup; hiding it
        // would lose real conversation.
        XCTAssertFalse(AgentTranscriptNoise.isNoise(userMessage("<my-element>hello</my-element>")))
        XCTAssertFalse(AgentTranscriptNoise.isNoise(userMessage("<Foo>hello</Foo>")))
        XCTAssertFalse(AgentTranscriptNoise.isNoise(userMessage("normal prompt")))
    }

    func testAssistantTurnsAreNeverNoise() {
        let message = AgentTranscriptMessage(
            id: "m",
            role: .assistant,
            blocks: [.text("<system-reminder>quoted by the agent</system-reminder>")]
        )

        XCTAssertFalse(AgentTranscriptNoise.isNoise(message))
    }

    func testTurnsCarryingToolBlocksAreNeverNoise() {
        let message = AgentTranscriptMessage(
            id: "m",
            role: .user,
            blocks: [
                .text("<system-reminder>x</system-reminder>"),
                .toolResult(AgentTranscriptToolResult(output: "real output")),
            ]
        )

        XCTAssertFalse(AgentTranscriptNoise.isNoise(message))
    }

    func testStrippedRemovesOnlyNoise() {
        let messages = [
            userMessage("<system-reminder>x</system-reminder>"),
            userMessage("real prompt"),
        ]

        XCTAssertEqual(AgentTranscriptNoise.stripped(messages).map(\.text), ["real prompt"])
    }
}

final class AgentTranscriptRowBuilderTests: XCTestCase {
    private func assistant(_ blocks: [AgentTranscriptBlock], id: String = "a") -> AgentTranscriptMessage {
        AgentTranscriptMessage(id: id, role: .assistant, blocks: blocks)
    }

    private func toolCall(_ name: String, preview: String = "") -> AgentTranscriptBlock {
        .toolCall(AgentTranscriptToolCall(name: name, preview: preview, detail: "{\"a\":1}"))
    }

    func testToolOnlyTurnsFoldIntoThePrecedingAssistantTurn() {
        let messages = [
            assistant([.text("working"), toolCall("Edit", preview: "foo.swift")], id: "a1"),
            AgentTranscriptMessage(
                id: "t1",
                role: .tool,
                blocks: [.toolResult(AgentTranscriptToolResult(output: "ok"))]
            ),
        ]

        let folded = AgentTranscriptRowBuilder.folded(messages)

        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].blocks.count, 3)
    }

    func testToolOnlyTurnWithoutAnAssistantPredecessorStandsAlone() {
        let messages = [
            AgentTranscriptMessage(
                id: "t1",
                role: .tool,
                blocks: [.toolResult(AgentTranscriptToolResult(output: "ok"))]
            ),
        ]

        XCTAssertEqual(AgentTranscriptRowBuilder.folded(messages).count, 1)
    }

    func testCallsAndResultsPairByOrdinal() {
        let blocks: [AgentTranscriptBlock] = [
            toolCall("Read", preview: "a.swift"),
            toolCall("Read", preview: "b.swift"),
            .toolResult(AgentTranscriptToolResult(output: "first")),
            .toolResult(AgentTranscriptToolResult(output: "second")),
        ]

        let runs = AgentTranscriptRowBuilder.toolRuns(in: blocks)

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].call?.preview, "a.swift")
        XCTAssertEqual(runs[0].result?.output, "first")
        XCTAssertEqual(runs[1].result?.output, "second")
    }

    func testOrphanResultBecomesItsOwnRun() {
        let runs = AgentTranscriptRowBuilder.toolRuns(in: [
            .toolResult(AgentTranscriptToolResult(output: "dangling")),
        ])

        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs[0].call)
        XCTAssertEqual(runs[0].result?.output, "dangling")
    }

    func testCollapsedToolRunIsOneRow() {
        let rows = AgentTranscriptRowBuilder.rows(messages: [
            assistant([.text("hi"), toolCall("Edit", preview: "foo.swift")]),
        ])

        XCTAssertEqual(rows.count, 3)
        guard case let .toolRun(_, run, isExpanded) = rows[2] else {
            return XCTFail("expected a tool run row")
        }
        XCTAssertFalse(isExpanded)
        XCTAssertEqual(run.summary, "Edit  foo.swift")
    }

    func testExpandingAToolRunAddsDetailAndOutputRowsInPlace() {
        let messages = [
            assistant([
                toolCall("Bash", preview: "ls"),
                .toolResult(AgentTranscriptToolResult(output: "total 0")),
            ]),
        ]
        var foldState = AgentTranscriptFoldState()
        let collapsed = AgentTranscriptRowBuilder.rows(messages: messages, foldState: foldState)
        guard case let .toolRun(runID, _, _) = collapsed[1] else {
            return XCTFail("expected a tool run row")
        }

        XCTAssertTrue(foldState.toggle(runID))
        let expanded = AgentTranscriptRowBuilder.rows(messages: messages, foldState: foldState)

        XCTAssertEqual(expanded.count, collapsed.count + 2)
        guard case .toolDetail = expanded[2], case .toolOutput = expanded[3] else {
            return XCTFail("expected detail then output rows")
        }
    }

    func testExpandingAnEditToolRunPrefersTheDiffOverRawInput() {
        let call = AgentTranscriptToolPresentation.toolCall(
            name: "Edit",
            input: ["file_path": "/tmp/a.swift", "old_string": "x", "new_string": "y"]
        )
        let messages = [assistant([.toolCall(call)])]
        var foldState = AgentTranscriptFoldState()
        guard case let .toolRun(runID, _, _) = AgentTranscriptRowBuilder.rows(messages: messages)[1] else {
            return XCTFail("expected a tool run row")
        }
        foldState.toggle(runID)

        let rows = AgentTranscriptRowBuilder.rows(messages: messages, foldState: foldState)

        guard case let .toolDiff(_, diff) = rows[2] else {
            return XCTFail("expected a diff row")
        }
        XCTAssertEqual(diff.lines.map(\.text), ["x", "y"])
    }

    func testTogglingTwiceCollapsesAgain() {
        var foldState = AgentTranscriptFoldState()

        XCTAssertTrue(foldState.toggle("run"))
        XCTAssertTrue(foldState.isExpanded("run"))
        XCTAssertFalse(foldState.toggle("run"))
        XCTAssertFalse(foldState.isExpanded("run"))
    }

    func testCollapseAllClearsEveryExpansion() {
        var foldState = AgentTranscriptFoldState(expandedRunIDs: ["a", "b"])

        foldState.collapseAll()

        XCTAssertFalse(foldState.isExpanded("a"))
        XCTAssertFalse(foldState.isExpanded("b"))
    }

    func testNoiseIsFilteredBeforeRowsAreBuilt() {
        let rows = AgentTranscriptRowBuilder.rows(messages: [
            AgentTranscriptMessage(
                id: "n",
                role: .user,
                blocks: [.text("<system-reminder>machinery</system-reminder>")]
            ),
            AgentTranscriptMessage(id: "u", role: .user, blocks: [.text("real prompt")]),
        ])

        XCTAssertEqual(rows.count, 2)
        guard case let .text(_, _, text) = rows[1] else {
            return XCTFail("expected a text row")
        }
        XCTAssertEqual(text, "real prompt")
    }

    func testRowIdentitiesAreUniqueSoTheListCanDiff() {
        let rows = AgentTranscriptRowBuilder.rows(
            messages: [
                assistant([
                    .text("one"),
                    toolCall("Read", preview: "a"),
                    toolCall("Read", preview: "b"),
                ]),
            ],
            foldState: AgentTranscriptFoldState()
        )

        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}

@MainActor
final class AgentSessionTranscriptViewPresentationTests: XCTestCase {
    func testCollapsedAndExpandedRunLabelsUseDisclosureGlyphs() {
        let run = AgentTranscriptToolRun(
            call: AgentTranscriptToolCall(name: "Edit", preview: "src/foo.swift")
        )

        XCTAssertEqual(
            AgentSessionTranscriptView.toolRunLabel(run: run, isExpanded: false),
            "▸ Edit  src/foo.swift"
        )
        XCTAssertEqual(
            AgentSessionTranscriptView.toolRunLabel(run: run, isExpanded: true),
            "▾ Edit  src/foo.swift"
        )
    }

    func testRunWithoutAPreviewShowsOnlyTheToolName() {
        let run = AgentTranscriptToolRun(call: AgentTranscriptToolCall(name: "TodoWrite"))

        XCTAssertEqual(
            AgentSessionTranscriptView.toolRunLabel(run: run, isExpanded: false),
            "▸ TodoWrite"
        )
    }

    func testDiffLinesArePrefixedByKind() {
        XCTAssertEqual(
            AgentSessionTranscriptView.diffLineText(.init(kind: .removed, text: "old")),
            "- old"
        )
        XCTAssertEqual(
            AgentSessionTranscriptView.diffLineText(.init(kind: .added, text: "new")),
            "+ new"
        )
    }

    func testSessionKeySeparatesAgentsSharingAnIdentifier() {
        let claude = AgentSessionRecord(
            agent: .claudeCode,
            sessionID: "shared",
            title: "t",
            cwd: "/tmp",
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 1,
            filePath: "/tmp/a.jsonl"
        )
        let codex = AgentSessionRecord(
            agent: .codex,
            sessionID: "shared",
            title: "t",
            cwd: "/tmp",
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 1,
            filePath: "/tmp/b.jsonl"
        )

        XCTAssertNotEqual(
            AgentSessionTranscriptPresenter.sessionKey(for: claude),
            AgentSessionTranscriptPresenter.sessionKey(for: codex)
        )
    }
}

@MainActor
final class AgentSessionTranscriptControllerTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-transcript-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
        try super.tearDownWithError()
    }

    private func makeRecord(fileURL: URL) -> AgentSessionRecord {
        AgentSessionRecord(
            agent: .claudeCode,
            sessionID: "session",
            title: "Session",
            cwd: "/tmp",
            updatedAt: Date(),
            createdAt: Date(),
            messageCount: 0,
            filePath: fileURL.path
        )
    }

    func testInitialTailIsPaintedOffTheMainActorAndDeliveredAsRows() throws {
        let fileURL = directoryURL.appendingPathComponent("session.jsonl")
        try Data("""
        {"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}
        {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"hi"}]}}

        """.utf8).write(to: fileURL)
        let controller = AgentSessionTranscriptController(record: makeRecord(fileURL: fileURL))
        let painted = expectation(description: "initial tail painted")
        controller.onChange = { snapshot in
            guard snapshot.messageCount == 2 else { return }
            painted.fulfill()
        }

        controller.start()
        wait(for: [painted], timeout: 5)
        controller.stop()

        XCTAssertEqual(controller.snapshot.messageCount, 2)
        XCTAssertFalse(controller.snapshot.rows.isEmpty)
    }

    func testAppendedRecordsArriveThroughTheWatcher() throws {
        let fileURL = directoryURL.appendingPathComponent("session.jsonl")
        try Data((#"{"type":"user","uuid":"u1","message":{"content":"one"}}"# + "\n").utf8)
            .write(to: fileURL)
        let controller = AgentSessionTranscriptController(record: makeRecord(fileURL: fileURL))
        let appended = expectation(description: "appended record observed")
        controller.onChange = { snapshot in
            guard snapshot.messageCount == 2 else { return }
            appended.fulfill()
        }
        controller.start()

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"user","uuid":"u2","message":{"content":"two"}}"# + "\n").utf8))
        try handle.close()

        wait(for: [appended], timeout: 10)
        controller.stop()
    }
}
