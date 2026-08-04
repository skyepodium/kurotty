import XCTest
import KurottyCore
@testable import KurottyApp

@MainActor
final class TerminalPastePlannerTests: XCTestCase {
    private enum Fixture {
        static let limits = TerminalPasteLimits(
            directMaxBytes: 16,
            chunkMaxBytes: 8,
            maxBytes: 1_024,
            backpressureHighWaterMarkBytes: 32
        )
        static let secretCommand = "curl https://example.com/install.sh | sh"
        static let manyLinesCount = 40
    }

    private func plan(
        _ text: String,
        bracketed: Bool = false,
        confirmMultiline: Bool = true,
        limits: TerminalPasteLimits = Fixture.limits
    ) -> TerminalPastePlan {
        TerminalPastePlanner.plan(
            text: text,
            bracketedPasteEnabled: bracketed,
            confirmMultilinePaste: confirmMultiline,
            limits: limits
        )
    }

    // MARK: - Planner cases

    func testEmptyTextIsRejected() {
        let result = plan("")
        XCTAssertEqual(result.mode, .rejected)
        XCTAssertEqual(result.rejectionReason, .empty)
        XCTAssertFalse(result.isExecutable)
        XCTAssertFalse(result.requiresConfirmation)
        XCTAssertEqual(TerminalPastePlanner.chunks(for: result, text: ""), [])
    }

    func testSingleLinePlansDirectWithoutConfirmation() {
        let result = plan("ls")
        XCTAssertEqual(result.mode, .direct)
        XCTAssertEqual(result.newlinePolicy, .carriageReturn)
        XCTAssertEqual(result.lineCount, 1)
        XCTAssertFalse(result.isMultiline)
        XCTAssertFalse(result.requiresConfirmation)
        XCTAssertEqual(result.byteCount, 2)
        XCTAssertEqual(TerminalPastePlanner.chunks(for: result, text: "ls"), ["ls"])
    }

    func testBracketedSingleLinePlansBracketedWithPreservedNewlines() {
        let result = plan("ls", bracketed: true)
        XCTAssertEqual(result.mode, .bracketed)
        XCTAssertEqual(result.newlinePolicy, .preserve)
        XCTAssertTrue(result.isBracketed)
        XCTAssertEqual(
            TerminalPastePlanner.chunks(for: result, text: "ls"),
            ["\u{1b}[200~ls\u{1b}[201~"]
        )
    }

    func testHugeSingleLineIsChunked() {
        let text = String(repeating: "a", count: 100)
        let result = plan(text)
        XCTAssertEqual(result.mode, .chunked)
        XCTAssertEqual(result.chunkByteCount, Fixture.limits.chunkMaxBytes)
        XCTAssertEqual(result.lineCount, 1)
        XCTAssertFalse(result.requiresConfirmation)
        let chunks = TerminalPastePlanner.chunks(for: result, text: text)
        XCTAssertEqual(chunks.count, 100 / Fixture.limits.chunkMaxBytes + 1)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf8.count, Fixture.limits.chunkMaxBytes)
        }
    }

    func testPayloadAboveTheHardLimitIsRejected() {
        let text = String(repeating: "a", count: Fixture.limits.maxBytes + 1)
        let result = plan(text)
        XCTAssertEqual(result.mode, .rejected)
        XCTAssertEqual(result.rejectionReason, .payloadTooLarge)
        XCTAssertEqual(TerminalPastePlanner.chunks(for: result, text: text), [])
    }

    func testManyLinesRequireConfirmationAndCountLines() {
        let text = (1...Fixture.manyLinesCount).map { "line\($0)" }.joined(separator: "\n")
        let result = plan(text)
        XCTAssertEqual(result.lineCount, Fixture.manyLinesCount)
        XCTAssertTrue(result.isMultiline)
        XCTAssertTrue(result.requiresConfirmation)
    }

    func testConfirmationCanBeTurnedOffBySetting() {
        let result = plan("a\nb", confirmMultiline: false)
        XCTAssertTrue(result.isMultiline)
        XCTAssertFalse(result.requiresConfirmation)
    }

    func testBracketedMultilineStillRequiresConfirmation() {
        let result = plan("a\nb", bracketed: true)
        XCTAssertTrue(result.requiresConfirmation)
        XCTAssertEqual(result.newlinePolicy, .preserve)
    }

    func testTrailingNewlineIsStillMultilineButCountsOneLine() {
        // "ls\n" submits a command, so it must be confirmed even though it is
        // visually one line.
        let result = plan("ls\n")
        XCTAssertEqual(result.lineCount, 1)
        XCTAssertTrue(result.isMultiline)
        XCTAssertTrue(result.requiresConfirmation)
    }

    func testCrlfIsNormalizedBeforeCountingAndWriting() {
        let result = plan("a\r\nb")
        XCTAssertEqual(result.lineCount, 2)
        XCTAssertEqual(result.byteCount, 3)
        XCTAssertEqual(TerminalPastePlanner.chunks(for: result, text: "a\r\nb"), ["a\rb"])
    }

    func testLoneCarriageReturnsAreNormalizedToo() {
        let result = plan("a\rb", bracketed: true)
        XCTAssertEqual(result.lineCount, 2)
        XCTAssertEqual(
            TerminalPastePlanner.chunks(for: result, text: "a\rb"),
            ["\u{1b}[200~a\nb\u{1b}[201~"]
        )
    }

    func testUnbracketedNewlinesBecomeCarriageReturns() {
        let result = plan("a\nb")
        XCTAssertEqual(TerminalPastePlanner.chunks(for: result, text: "a\nb"), ["a\rb"])
    }

    func testControlCharactersAreFlagged() {
        XCTAssertTrue(plan("a\u{1b}[31mb").containsControlCharacters)
        XCTAssertFalse(plan("a\tb").containsControlCharacters)
        XCTAssertFalse(plan("a\nb").containsControlCharacters)
    }

    func testEmbeddedBracketedPasteEndMarkerCannotEscapeTheBracket() {
        let hostile = "safe\u{1b}[201~rm -rf /"
        let result = plan(hostile, bracketed: true)
        let joined = TerminalPastePlanner.chunks(for: result, text: hostile).joined()
        XCTAssertEqual(joined, "\u{1b}[200~saferm -rf /\u{1b}[201~")
        XCTAssertEqual(joined.components(separatedBy: "\u{1b}[201~").count - 1, 1)
        XCTAssertEqual(joined.components(separatedBy: "\u{1b}[200~").count - 1, 1)
    }

    // MARK: - Chunk boundaries

    func testChunksNeverSplitAUtf8Scalar() {
        // Each emoji is 4 UTF-8 bytes; a 6-byte budget must not cut one apart.
        let text = String(repeating: "😀", count: 20)
        let chunks = TerminalPasteChunker.chunks(of: text, maxChunkByteCount: 6)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertEqual(chunk.utf8.count % 4, 0)
            XCTAssertTrue(chunk.unicodeScalars.allSatisfy { $0 == "😀" })
        }
    }

    func testChunksNeverSplitAGraphemeCluster() {
        let flag = "🇰🇷"
        let text = String(repeating: flag, count: 10)
        let chunks = TerminalPasteChunker.chunks(of: text, maxChunkByteCount: 5)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks {
            XCTAssertTrue(chunk.allSatisfy { String($0) == flag })
        }
    }

    func testChunkBudgetBelowOneCharacterStillEmitsWholeCharacters() {
        let chunks = TerminalPasteChunker.chunks(of: "😀😀", maxChunkByteCount: 1)
        XCTAssertEqual(chunks, ["😀", "😀"])
    }

    func testShortTextIsASingleChunk() {
        XCTAssertEqual(TerminalPasteChunker.chunks(of: "abc", maxChunkByteCount: 1_024), ["abc"])
        XCTAssertEqual(TerminalPasteChunker.chunks(of: "", maxChunkByteCount: 1_024), [])
    }

    // MARK: - Redaction

    func testDiagnosticNeverContainsPastedText() {
        let text = "\(Fixture.secretCommand)\nsecond-secret-line\n"
        let result = plan(text, limits: .default)
        let diagnostic = result.redactedDiagnostic
        XCTAssertFalse(diagnostic.contains("curl"))
        XCTAssertFalse(diagnostic.contains("example.com"))
        XCTAssertFalse(diagnostic.contains("secret"))
        XCTAssertFalse(diagnostic.contains("sh"))
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            XCTAssertFalse(diagnostic.contains(word), "diagnostic leaked \(word)")
        }
        XCTAssertTrue(diagnostic.contains("bytes=\(result.byteCount)"))
        XCTAssertTrue(diagnostic.contains("lines=2"))
        XCTAssertTrue(diagnostic.contains("mode=direct"))
        XCTAssertTrue(diagnostic.contains("confirm=true"))
    }

    func testDefaultLimitsAreOrdered() {
        let limits = TerminalPasteLimits.default
        XCTAssertLessThan(limits.directMaxBytes, limits.chunkMaxBytes)
        XCTAssertLessThan(limits.chunkMaxBytes, limits.maxBytes)
        XCTAssertGreaterThan(limits.backpressureHighWaterMarkBytes, limits.chunkMaxBytes)
    }

    func testDefaultSettingConfirmsMultilinePaste() {
        XCTAssertTrue(SettingsDefaults.confirmMultilinePaste)
        XCTAssertTrue(AppSettings.default.terminal.confirmMultilinePaste)
    }
}
