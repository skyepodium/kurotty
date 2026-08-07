import XCTest
@testable import KurottyCore
@testable import KurottyApp

/// Byte-level contract for scrollback snapshots: content addressing, UTF-8
/// clipping, budgets, atomic writes, and pruning.
final class TerminalScrollbackSnapshotFormatTests: XCTestCase {
    private enum Fixture {
        static let tabID = "tab-a"
        static let paneID = "pane-1"
        /// Three bytes per syllable in UTF-8.
        static let korean = "안녕하세요"
        /// Four bytes.
        static let emoji = "😀"
        /// "e" plus U+0301 COMBINING ACUTE ACCENT: two scalars, three bytes.
        static let combining = "e\u{0301}"
    }

    // MARK: - Content addressing

    func testRefIsStableAcrossCalls() {
        let first = TerminalScrollbackSnapshotFormat.ref(tabID: Fixture.tabID, paneID: Fixture.paneID)
        let second = TerminalScrollbackSnapshotFormat.ref(tabID: Fixture.tabID, paneID: Fixture.paneID)

        XCTAssertEqual(first, second)
        XCTAssertTrue(TerminalScrollbackSnapshotFormat.isValidRef(first))
        XCTAssertTrue(first.hasPrefix("v2-"))
        XCTAssertEqual(first.count, "v2-".count + TerminalScrollbackSnapshotFormat.refHashCharacterCount)
    }

    func testRefSeparatesTabAndPaneWithNulByte() {
        // Without the NUL separator these two panes would hash identically.
        let left = TerminalScrollbackSnapshotFormat.ref(tabID: "ab", paneID: "c")
        let right = TerminalScrollbackSnapshotFormat.ref(tabID: "a", paneID: "bc")

        XCTAssertNotEqual(left, right)
    }

    func testInvalidRefsAreRejected() {
        let cases = [
            "",
            "v2-",
            "v1-0123456789abcdef0123456789abcdef",
            "v2-0123456789ABCDEF0123456789abcdef",
            "v2-0123456789abcdef0123456789abcde",
            "v2-0123456789abcdef0123456789abcdefa",
            "v2-../../etc/passwd0123456789abcdef",
        ]
        for candidate in cases {
            XCTAssertFalse(
                TerminalScrollbackSnapshotFormat.isValidRef(candidate),
                "expected \(candidate) to be rejected"
            )
            XCTAssertNil(TerminalScrollbackSnapshotFormat.fileName(forRef: candidate))
        }
    }

    // MARK: - UTF-8 trailing clip

    func testTrailingClipKeepsWholeDataUnderBudget() {
        let data = Data("hello".utf8)

        XCTAssertEqual(TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: 64), data)
    }

    func testTrailingClipNeverSplitsKoreanSyllable() {
        let data = Data(Fixture.korean.utf8)
        XCTAssertEqual(data.count, 15)

        // 7 bytes lands inside the third syllable; the clip must advance to the
        // start of the fourth.
        let clipped = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: 7)

        XCTAssertEqual(clipped.count, 6)
        XCTAssertEqual(String(decoding: clipped, as: UTF8.self), "세요")
    }

    func testTrailingClipNeverSplitsEmoji() {
        let data = Data(("ab" + Fixture.emoji).utf8)
        XCTAssertEqual(data.count, 6)

        for budget in 1...3 {
            let clipped = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: budget)
            XCTAssertEqual(String(decoding: clipped, as: UTF8.self), "", "budget \(budget)")
        }
        let exact = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: 4)
        XCTAssertEqual(String(decoding: exact, as: UTF8.self), Fixture.emoji)
    }

    func testTrailingClipKeepsCombiningMarkAttachedOrDropsBothScalars() {
        let data = Data(("x" + Fixture.combining).utf8)
        XCTAssertEqual(data.count, 4)

        // 2 bytes falls inside the two-byte combining mark, so the clip yields
        // only the complete trailing scalar.
        let clipped = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: 2)
        XCTAssertEqual(String(decoding: clipped, as: UTF8.self), "\u{0301}")

        let wider = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: 3)
        XCTAssertEqual(String(decoding: wider, as: UTF8.self), Fixture.combining)
    }

    func testTrailingClipOnExactBoundaryKeepsEveryByte() {
        let data = Data(Fixture.korean.utf8)

        let clipped = TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(data, maximumBytes: 6)

        XCTAssertEqual(clipped.count, 6)
        XCTAssertEqual(String(decoding: clipped, as: UTF8.self), "세요")
    }

    func testZeroBudgetYieldsNoBytes() {
        XCTAssertTrue(
            TerminalScrollbackSnapshotFormat.trailingUTF8Bytes(Data("abc".utf8), maximumBytes: 0).isEmpty
        )
    }

    // MARK: - Replay payload

    func testReplayPayloadAdvancesToRowBoundaryWhenClipped() {
        let stored = Data("first\r\nsecond\r\nthird\r\n".utf8)

        // A budget that lands inside "second" must not start replay mid-row.
        let payload = TerminalScrollbackSnapshotFormat.replayPayload(from: stored, maximumBytes: 14)

        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "third\r\n")
    }

    func testReplayPayloadKeepsEverythingWhenUnderBudget() {
        let stored = Data("first\r\nsecond\r\n".utf8)

        let payload = TerminalScrollbackSnapshotFormat.replayPayload(from: stored, maximumBytes: 4_096)

        XCTAssertEqual(payload, stored)
    }
}

final class TerminalScrollbackSnapshotSerializerTests: XCTestCase {
    private func row(_ text: String, style: TerminalTextStyle = .default, columns: Int = 12) -> [TerminalScreenCell] {
        var cells = Array(
            repeating: TerminalScreenCell(character: " ", style: .default),
            count: columns
        )
        for (index, character) in text.enumerated() where index < columns {
            cells[index] = TerminalScreenCell(character: character, style: style)
        }
        return cells
    }

    func testTrailingBlanksAreDropped() {
        let encoded = TerminalScrollbackSnapshotSerializer.encoded(
            row: row("hi"),
            defaultStyle: .default
        )

        XCTAssertEqual(encoded, "hi")
    }

    func testStyledTrailingBlanksAreDroppedBeforeReplay() {
        let black = SIMD4<Float>(0, 0, 0, 1)
        let promptStyle = TerminalTextStyle(
            foreground: SIMD4<Float>(1, 1, 1, 1),
            background: black,
            foregroundSource: .defaultColor,
            backgroundSource: .ansi
        )
        var cells = row("prompt", style: promptStyle)
        for index in 6..<cells.count {
            cells[index] = TerminalScreenCell(character: " ", style: promptStyle)
        }

        let encoded = TerminalScrollbackSnapshotSerializer.encoded(
            row: cells,
            defaultStyle: .default
        )

        XCTAssertFalse(encoded.hasSuffix(String(repeating: " ", count: 6)))
        XCTAssertTrue(encoded.contains("prompt"))
    }

    func testRowsSerializeOldestFirstWithCarriageReturnNewline() {
        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: [row("one"), row("two")],
            defaultStyle: .default
        )

        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "one\r\ntwo\r\n")
    }

    func testBudgetKeepsOnlyTrailingWholeRows() {
        let rows = [row("aaaa"), row("bbbb"), row("cccc")]
        let wholeSize = TerminalScrollbackSnapshotSerializer.serialize(
            rows: rows,
            defaultStyle: .default
        ).count

        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: rows,
            defaultStyle: .default,
            maximumBytes: wholeSize - 1
        )

        // A row is never half-written, so the oldest row drops out entirely.
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "bbbb\r\ncccc\r\n")
    }

    func testStyledRunEmitsSgrAndResets() {
        let styled = TerminalTextStyle(
            foreground: TerminalTextStyle.rgb(red: 255, green: 0, blue: 0),
            background: TerminalTextStyle.default.background,
            bold: true
        )

        let encoded = TerminalScrollbackSnapshotSerializer.encoded(
            row: row("hi", style: styled),
            defaultStyle: .default
        )

        XCTAssertEqual(encoded, "\u{1b}[0;1;38;2;255;0;0mhi\u{1b}[0m")
    }

    func testPayloadCarriesNoDeviceQueriesOrOscSequences() {
        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: [row("plain"), row("안녕")],
            defaultStyle: .default
        )
        let text = String(decoding: payload, as: UTF8.self)

        // Replay must never make the terminal answer something into a new
        // shell, so every escape sequence in the payload has to be SGR.
        XCTAssertFalse(text.contains("\u{1b}]"), "no OSC")
        XCTAssertFalse(text.contains("\u{1b}P"), "no DCS")
        for sequence in text.components(separatedBy: "\u{1b}[").dropFirst() {
            let finalByte = sequence.first { character in
                character.isLetter || character == "@" || character == "`"
            }
            XCTAssertEqual(finalByte, "m", "unexpected non-SGR sequence: \(sequence)")
        }
    }

    func testMultiByteRowsSurviveSerialization() {
        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: [row("안녕하세요"), row("😀ok")],
            defaultStyle: .default
        )

        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "안녕하세요\r\n😀ok\r\n")
    }

    func testBoundedScrollbackRowsOverloadUsesRetainedRows() {
        var scrollback = BoundedScrollbackRows()
        scrollback.append(contentsOf: [row("one"), row("two"), row("three")], limit: 2)

        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: scrollback,
            defaultStyle: .default
        )

        // "one" was trimmed by the row limit before the snapshot was taken.
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "two\r\nthree\r\n")
    }
}

final class TerminalScrollbackSnapshotStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-scrollback-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    private func makeStore() -> TerminalScrollbackSnapshotStore {
        TerminalScrollbackSnapshotStore(rootURL: rootURL)
    }

    private func ref(_ paneID: String = "pane") -> String {
        TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: paneID)
    }

    func testWriteThenReadRoundTrips() throws {
        let store = makeStore()
        let payload = Data("hello\r\n".utf8)

        let url = try store.write(ref: ref(), payload: payload)

        XCTAssertNotNil(url)
        XCTAssertEqual(store.read(ref: ref()), payload)
    }

    func testWriteLeavesNoTemporaryFilesBehind() throws {
        let store = makeStore()

        _ = try store.write(ref: ref(), payload: Data("first\r\n".utf8))
        _ = try store.write(ref: ref(), payload: Data("second\r\n".utf8))

        let contents = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".tmp") }, [])
        // The rename replaced the previous snapshot in place rather than
        // leaving two files.
        XCTAssertEqual(store.snapshotFileURLs().count, 1)
        XCTAssertEqual(store.read(ref: ref()), Data("second\r\n".utf8))
    }

    func testWriteRejectsMalformedRef() {
        let store = makeStore()

        XCTAssertThrowsError(try store.write(ref: "../escape", payload: Data("x".utf8))) { error in
            XCTAssertEqual(error as? TerminalScrollbackSnapshotStore.StoreError, .invalidRef("../escape"))
        }
    }

    func testEmptyPayloadRemovesExistingSnapshot() throws {
        let store = makeStore()
        _ = try store.write(ref: ref(), payload: Data("hello\r\n".utf8))

        let url = try store.write(ref: ref(), payload: Data())

        XCTAssertNil(url)
        XCTAssertNil(store.read(ref: ref()))
    }

    func testStoreBudgetClipsWrittenBytesOnScalarBoundary() throws {
        let store = makeStore()
        let payload = Data("안녕하세요".utf8)

        _ = try store.write(ref: ref(), payload: payload, maximumBytes: 7)

        let stored = try XCTUnwrap(store.read(ref: ref()))
        XCTAssertEqual(stored.count, 6)
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), "세요")
    }

    func testReplayBudgetIsIndependentOfStoreBudget() throws {
        let store = makeStore()
        _ = try store.write(ref: ref(), payload: Data("aaa\r\nbbb\r\nccc\r\n".utf8))

        let replay = try XCTUnwrap(store.readReplayPayload(ref: ref(), maximumBytes: 9))

        // The whole file is still on disk; only the replay window is smaller.
        XCTAssertEqual(store.read(ref: ref())?.count, 15)
        XCTAssertEqual(String(decoding: replay, as: UTF8.self), "ccc\r\n")
    }

    func testPruneRemovesUnreferencedSnapshots() throws {
        let store = makeStore()
        _ = try store.write(ref: ref("live"), payload: Data("live\r\n".utf8))
        _ = try store.write(ref: ref("dead"), payload: Data("dead\r\n".utf8))

        let report = store.prune(keepingRefs: [ref("live")])

        XCTAssertEqual(report.unreferencedRemovedCount, 1)
        XCTAssertEqual(report.overBudgetRemovedCount, 0)
        XCTAssertNotNil(store.read(ref: ref("live")))
        XCTAssertNil(store.read(ref: ref("dead")))
    }

    func testPruneEnforcesTotalDirectoryBudget() throws {
        let store = makeStore()
        let refs = ["a", "b", "c"].map(ref)
        for (index, snapshotRef) in refs.enumerated() {
            _ = try store.write(ref: snapshotRef, payload: Data(repeating: UInt8(ascii: "x"), count: 100))
            // Distinct modification times so the eviction order is defined.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: XCTUnwrap(store.fileURL(forRef: snapshotRef)).path
            )
        }

        let report = store.prune(keepingRefs: Set(refs), totalByteBudget: 250)

        XCTAssertEqual(report.overBudgetRemovedCount, 1)
        XCTAssertEqual(report.retainedByteCount, 200)
        // The oldest snapshot is the one that goes.
        XCTAssertNil(store.read(ref: refs[0]))
        XCTAssertNotNil(store.read(ref: refs[1]))
        XCTAssertNotNil(store.read(ref: refs[2]))
    }

    func testTotalByteCountIgnoresForeignFiles() throws {
        let store = makeStore()
        _ = try store.write(ref: ref(), payload: Data(repeating: 0x41, count: 32))
        try Data("noise".utf8).write(to: rootURL.appendingPathComponent("README.txt"))

        XCTAssertEqual(store.totalByteCount(), 32)
    }

    func testWriterFlushesEnqueuedWork() throws {
        let store = makeStore()
        let writer = TerminalScrollbackSnapshotWriter(store: store)

        writer.write(ref: ref(), payload: Data("queued\r\n".utf8))
        writer.waitForPendingWork()

        XCTAssertEqual(store.read(ref: ref()), Data("queued\r\n".utf8))
    }
}

/// Recording replay target, standing in for the interpreter until the shared
/// `isReplayingScrollback` flag lands on it.
@MainActor
private final class RecordingReplayTarget: TerminalScrollbackReplayTarget {
    var isReplayingScrollback = false
    private(set) var consumed: [String] = []
    private(set) var flagStatesDuringConsume: [Bool] = []

    func consumeReplayedScrollback(_ text: String) {
        consumed.append(text)
        flagStatesDuringConsume.append(isReplayingScrollback)
    }
}

@MainActor
final class TerminalScrollbackReplayTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kurotty-scrollback-replay-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
        try super.tearDownWithError()
    }

    func testReplayRaisesFlagWhileParsingAndLowersItAfter() {
        let target = RecordingReplayTarget()

        let report = TerminalScrollbackReplayer.replay(payload: Data("hello\r\n".utf8), into: target)

        XCTAssertEqual(target.consumed, ["hello\r\n"])
        XCTAssertEqual(target.flagStatesDuringConsume, [true])
        XCTAssertFalse(target.isReplayingScrollback)
        XCTAssertTrue(report.didMarkReplayFlag)
        XCTAssertEqual(report.byteCount, 7)
    }

    func testEmptyPayloadNeverRaisesFlag() {
        let target = RecordingReplayTarget()

        let report = TerminalScrollbackReplayer.replay(payload: Data(), into: target)

        XCTAssertEqual(report, .skipped)
        XCTAssertTrue(target.consumed.isEmpty)
        XCTAssertFalse(target.isReplayingScrollback)
    }

    func testRestoreFromCoordinatorMarksReplayFlagAndClearsIt() throws {
        let store = TerminalScrollbackSnapshotStore(rootURL: rootURL)
        let coordinator = TerminalScrollbackSnapshotCoordinator(store: store)
        let snapshotRef = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "pane")
        _ = try store.write(ref: snapshotRef, payload: Data("restored\r\n".utf8))
        let pane = WorkspacePaneSnapshot(id: "pane", scrollbackRef: snapshotRef)
        let candidate = try XCTUnwrap(WorkspaceScrollbackReplayCandidate(pane: pane))
        let target = RecordingReplayTarget()

        let report = coordinator.restore(candidate: candidate, into: target)

        XCTAssertTrue(report.didMarkReplayFlag)
        XCTAssertTrue(report.isFlagClearedAfterReplay)
        XCTAssertEqual(target.flagStatesDuringConsume, [true])
        XCTAssertEqual(target.consumed, ["restored\r\n"])
        XCTAssertFalse(target.isReplayingScrollback)
    }

    func testDisabledCoordinatorNeitherCapturesNorRestores() throws {
        let store = TerminalScrollbackSnapshotStore(rootURL: rootURL)
        let coordinator = TerminalScrollbackSnapshotCoordinator(store: store, isEnabled: false)
        let snapshotRef = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "pane")
        _ = try store.write(ref: snapshotRef, payload: Data("restored\r\n".utf8))
        let candidate = WorkspaceScrollbackReplayCandidate(
            pane: WorkspacePaneSnapshot(id: "pane", scrollbackRef: snapshotRef)
        )
        let target = RecordingReplayTarget()

        XCTAssertNil(coordinator.capture(.init(tabID: "tab", paneID: "pane", rows: [])))
        XCTAssertEqual(coordinator.restore(candidate: try XCTUnwrap(candidate), into: target), .skipped)
        XCTAssertTrue(target.consumed.isEmpty)
    }

    /// Regression: the writer used to pass the prune result straight into
    /// `completion?(...)`, so a caller that wanted no report skipped the prune
    /// entirely — optional chaining does not evaluate the argument.
    func testPruneRunsWithoutACompletionHandler() throws {
        let store = TerminalScrollbackSnapshotStore(rootURL: rootURL)
        let writer = TerminalScrollbackSnapshotWriter(store: store)
        let keptRef = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "kept")
        let orphanRef = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "orphan")
        _ = try store.write(ref: keptRef, payload: Data("kept\r\n".utf8))
        _ = try store.write(ref: orphanRef, payload: Data("orphan\r\n".utf8))

        writer.prune(keepingRefs: [keptRef])
        writer.waitForPendingWork()

        XCTAssertNotNil(store.read(ref: keptRef))
        XCTAssertNil(store.read(ref: orphanRef))
    }

    func testCaptureWritesSnapshotAndReturnsRef() throws {
        let store = TerminalScrollbackSnapshotStore(rootURL: rootURL)
        let writer = TerminalScrollbackSnapshotWriter(store: store)
        let coordinator = TerminalScrollbackSnapshotCoordinator(store: store, writer: writer)
        let row = [TerminalScreenCell(character: "안"), TerminalScreenCell(character: "녕")]

        let snapshotRef = try XCTUnwrap(coordinator.capture(
            .init(tabID: "tab", paneID: "pane", rows: [row])
        ))
        coordinator.flushPendingWrites()

        XCTAssertEqual(snapshotRef, TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "pane"))
        XCTAssertEqual(String(decoding: try XCTUnwrap(store.read(ref: snapshotRef)), as: UTF8.self), "안녕\r\n")
    }
}

/// End-to-end proof that a real interpreter, not just the recording stub,
/// paints restored bytes without answering the previous session's queries.
@MainActor
final class TerminalScrollbackInterpreterReplayTests: XCTestCase {
    private func makeInterpreter(
        onTerminalResponse: @escaping (String) -> Void,
        onOscQuery: @escaping (String) -> Void = { _ in }
    ) -> TerminalOutputInterpreter {
        let interpreter = TerminalOutputInterpreter(
            defaultStyle: .default,
            ansiColors: TerminalPalette.ansiNormal + TerminalPalette.ansiBright,
            maxScrollbackRows: 1_000
        )
        interpreter.host = TerminalOutputInterpreterHost(
            sendTerminalResponse: onTerminalResponse,
            respondToOscQuery: onOscQuery,
            dispatchTerminalIntegrationOsc: { _ in .ignored },
            publishTitle: {},
            handleTerminalIntegrationEvent: { _ in },
            handleDesktopNotificationEvent: { _ in },
            handleClipboardWriteEvent: { _ in },
            ringTerminalBell: {},
            updateScrollIndicator: {},
            maxScrollbackOffset: { _ in 0 },
            reportTerminalFocusIfNeeded: {},
            terminalCapabilityMetrics: { nil },
            terminalColorSchemeMode: { .dark }
        )
        return interpreter
    }

    func testReplayedCapabilityQueriesNeverReachTheShell() {
        var responses: [String] = []
        var oscQueries: [String] = []
        let interpreter = makeInterpreter(
            onTerminalResponse: { responses.append($0) },
            onOscQuery: { oscQueries.append($0) }
        )
        // A snapshot can contain the previous session's device-attribute and
        // cursor-position requests.
        let payload = Data("restored\u{1b}[c\u{1b}[6n\u{1b}]10;?\u{07}\r\n".utf8)

        let report = TerminalScrollbackReplayer.replay(payload: payload, into: interpreter)

        XCTAssertTrue(report.didMarkReplayFlag)
        XCTAssertEqual(responses, [])
        XCTAssertEqual(oscQueries, [])
        XCTAssertFalse(interpreter.isReplayingScrollback)
    }

    func testLiveQueriesStillAnswerAfterReplayFinishes() {
        var responses: [String] = []
        let interpreter = makeInterpreter(onTerminalResponse: { responses.append($0) })

        TerminalScrollbackReplayer.replay(payload: Data("restored\r\n".utf8), into: interpreter)
        interpreter.interpret("\u{1b}[c")

        XCTAssertFalse(responses.isEmpty, "the live shell must still receive its own reply")
    }

    func testReplayedRowsLandInTheScreenModel() {
        let interpreter = makeInterpreter(onTerminalResponse: { _ in })
        let rows = [
            [TerminalScreenCell(character: "안"), TerminalScreenCell(character: "녕")],
            [TerminalScreenCell(character: "o"), TerminalScreenCell(character: "k")],
        ]
        let payload = TerminalScrollbackSnapshotSerializer.serialize(
            rows: rows,
            defaultStyle: .default
        )

        TerminalScrollbackReplayer.replay(payload: payload, into: interpreter)

        // Wide glyphs occupy a lead cell plus a continuation cell, which is not
        // part of the text the row represents.
        let painted = interpreter.screen.cells
            .map { row in
                String(row.filter { !$0.isContinuation }.map(\.character))
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        XCTAssertTrue(painted.contains("안녕"), "painted rows: \(painted)")
        XCTAssertTrue(painted.contains("ok"), "painted rows: \(painted)")
    }
}

final class WorkspaceScrollbackSnapshotPlanTests: XCTestCase {
    private func snapshot(scrollbackRef: String?) -> WorkspaceSnapshot {
        WorkspaceSnapshot(windows: [
            WorkspaceWindowSnapshot(id: "window", tabs: [
                WorkspaceTabSnapshot(id: "tab", root: .pane(WorkspacePaneSnapshot(
                    id: "pane",
                    scrollbackRef: scrollbackRef
                ))),
            ]),
        ])
    }

    func testRestorePlanCarriesScrollbackCandidateSeparatelyFromCommandReplay() {
        let snapshotRef = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "pane")

        let plan = snapshot(scrollbackRef: snapshotRef).restorePlan

        XCTAssertEqual(plan.scrollbackReplayCandidates.map(\.scrollbackRef), [snapshotRef])
        // Scrollback bytes are display-only, so they never create a command
        // replay candidate or an unsafe-replay pane.
        XCTAssertTrue(plan.commandReplayCandidates.isEmpty)
        XCTAssertTrue(snapshot(scrollbackRef: snapshotRef).unsafeCommandReplayPaneIDs.isEmpty)
    }

    func testMalformedRefProducesNoRestoreCandidate() {
        XCTAssertTrue(snapshot(scrollbackRef: "../../etc/passwd").restorePlan.scrollbackReplayCandidates.isEmpty)
        XCTAssertTrue(snapshot(scrollbackRef: nil).restorePlan.scrollbackReplayCandidates.isEmpty)
    }

    func testSnapshotDecodesWithoutScrollbackRefForBackwardCompatibility() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "windows": [
            {
              "id": "window",
              "tabs": [
                {
                  "id": "tab",
                  "root": {
                    "kind": "pane",
                    "pane": {
                      "id": "pane",
                      "restoreSafety": {
                        "commandReplay": "disabled",
                        "capturedAtPromptBoundary": false
                      }
                    }
                  }
                }
              ]
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.windows.first?.panes.first?.scrollbackRef)
        XCTAssertTrue(decoded.scrollbackSnapshotRefs.isEmpty)
    }

    func testScrollbackSnapshotRefsCollectEveryPane() {
        let first = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "one")
        let second = TerminalScrollbackSnapshotFormat.ref(tabID: "tab", paneID: "two")
        let workspace = WorkspaceSnapshot(windows: [
            WorkspaceWindowSnapshot(id: "window", tabs: [
                WorkspaceTabSnapshot(id: "tab", root: .split(WorkspaceSplitSnapshot(
                    id: "split",
                    axis: .horizontal,
                    children: [
                        .pane(WorkspacePaneSnapshot(id: "one", scrollbackRef: first)),
                        .pane(WorkspacePaneSnapshot(id: "two", scrollbackRef: second)),
                    ]
                ))),
            ]),
        ])

        XCTAssertEqual(workspace.scrollbackSnapshotRefs, [first, second])
    }
}
