import XCTest
@testable import KurottyApp

/// Drives the paste executor without a PTY: the writer records chunks and can
/// pretend the PTY queue is backed up.
@MainActor
final class RecordingPasteWriter: TerminalPasteWriting {
    var chunks: [String] = []
    var queuedBytes: Int?
    /// Drains this many bytes off the simulated queue per write, so a paced
    /// paste eventually completes instead of spinning.
    var drainPerWrite = 0

    init(queuedBytes: Int? = nil) {
        self.queuedBytes = queuedBytes
    }

    func writePasteChunk(_ text: String) {
        chunks.append(text)
        if let queued = queuedBytes {
            queuedBytes = max(0, queued - drainPerWrite)
        }
    }

    var queuedPasteByteCount: Int? {
        queuedBytes
    }
}

@MainActor
final class TerminalPasteExecutorTests: XCTestCase {
    private let limits = TerminalPasteLimits(
        directMaxBytes: 4,
        chunkMaxBytes: 4,
        maxBytes: 4_096,
        backpressureHighWaterMarkBytes: 8
    )

    private func plan(_ text: String, bracketed: Bool = false) -> TerminalPastePlan {
        TerminalPastePlanner.plan(
            text: text,
            bracketedPasteEnabled: bracketed,
            confirmMultilinePaste: false,
            limits: limits
        )
    }

    func testDirectPasteWritesOneChunk() async {
        let writer = RecordingPasteWriter()
        let result = await TerminalPasteExecutor.execute(
            plan: plan("ls"),
            text: "ls",
            limits: limits,
            writer: writer
        )
        XCTAssertEqual(result.status, .pasted)
        XCTAssertEqual(result.chunksWritten, 1)
        XCTAssertEqual(result.bytesWritten, 2)
        XCTAssertEqual(writer.chunks, ["ls"])
    }

    func testChunkedPasteWritesEveryChunkInOrder() async {
        let text = String(repeating: "abcd", count: 5)
        let writer = RecordingPasteWriter()
        let result = await TerminalPasteExecutor.execute(
            plan: plan(text),
            text: text,
            limits: limits,
            writer: writer
        )
        XCTAssertEqual(result.status, .pasted)
        XCTAssertEqual(writer.chunks.count, 5)
        XCTAssertEqual(writer.chunks.joined(), text)
        XCTAssertEqual(result.bytesWritten, text.utf8.count)
    }

    func testRejectedPlanWritesNothing() async {
        let writer = RecordingPasteWriter()
        let result = await TerminalPasteExecutor.execute(
            plan: plan(""),
            text: "",
            limits: limits,
            writer: writer
        )
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(writer.chunks, [])
        XCTAssertEqual(result.chunksWritten, 0)
    }

    func testCancellationStopsBeforeTheNextChunk() async {
        let text = String(repeating: "abcd", count: 5)
        let writer = RecordingPasteWriter()
        var writesAllowed = 2
        let result = await TerminalPasteExecutor.execute(
            plan: plan(text),
            text: text,
            limits: limits,
            writer: writer
        ) {
            defer { writesAllowed -= 1 }
            return writesAllowed <= 0
        }
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(writer.chunks.count, 2)
    }

    func testBackpressurePausesUntilTheQueueDrains() async {
        let text = String(repeating: "abcd", count: 3)
        let writer = RecordingPasteWriter(queuedBytes: 24)
        writer.drainPerWrite = 24
        let result = await TerminalPasteExecutor.execute(
            plan: plan(text),
            text: text,
            limits: limits,
            writer: writer
        )
        // The first chunk waited out the backed-up queue instead of piling on,
        // and every chunk still arrived.
        XCTAssertEqual(result.status, .pasted)
        XCTAssertEqual(writer.chunks.joined(), text)
        XCTAssertEqual(writer.queuedBytes, 0)
    }

    func testWriterWithoutBackpressureReportingIsNeverBlocked() async {
        let text = String(repeating: "abcd", count: 3)
        let writer = RecordingPasteWriter(queuedBytes: nil)
        let result = await TerminalPasteExecutor.execute(
            plan: plan(text),
            text: text,
            limits: limits,
            writer: writer
        )
        XCTAssertEqual(result.status, .pasted)
        XCTAssertEqual(writer.chunks.joined(), text)
    }

    func testExecutionDiagnosticIsRedacted() async {
        let secret = "export TOKEN=abcdef123456"
        let writer = RecordingPasteWriter()
        let result = await TerminalPasteExecutor.execute(
            plan: plan(secret),
            text: secret,
            limits: limits,
            writer: writer
        )
        XCTAssertFalse(result.redactedDiagnostic.contains("TOKEN"))
        XCTAssertFalse(result.redactedDiagnostic.contains("abcdef123456"))
    }

    // MARK: - Confirmation gate

    /// The gate is a plan-level contract: nothing may be written while a plan
    /// still requires confirmation.
    func testConfirmationGateBlocksExecutionUntilConfirmed() async {
        let text = "line1\nline2\nline3"
        let gatedPlan = TerminalPastePlanner.plan(
            text: text,
            bracketedPasteEnabled: false,
            confirmMultilinePaste: true,
            limits: limits
        )
        XCTAssertTrue(gatedPlan.requiresConfirmation)

        let writer = RecordingPasteWriter()
        var confirmed = false
        // The surface only calls the executor once confirmation returned true.
        if !gatedPlan.requiresConfirmation || confirmed {
            _ = await TerminalPasteExecutor.execute(
                plan: gatedPlan,
                text: text,
                limits: limits,
                writer: writer
            )
        }
        XCTAssertEqual(writer.chunks, [], "paste ran before the user confirmed")

        confirmed = true
        if !gatedPlan.requiresConfirmation || confirmed {
            _ = await TerminalPasteExecutor.execute(
                plan: gatedPlan,
                text: text,
                limits: limits,
                writer: writer
            )
        }
        XCTAssertEqual(writer.chunks.joined(), "line1\rline2\rline3")
    }

    func testSurfacePasteRoutesThroughThePlannerAndConfirmationGate() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/KurottyApp/TerminalSurfaceView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("TerminalPastePlanner.plan("))
        XCTAssertTrue(source.contains("guard plan.requiresConfirmation else {"))
        XCTAssertTrue(source.contains("presentMultilinePasteConfirmation(plan)"))
        XCTAssertTrue(source.contains("TerminalPasteExecutor.execute("))
        // The old unconditional direct write must be gone.
        XCTAssertFalse(source.contains("send(\"\\u{1b}[200~\\(text)\\u{1b}[201~\")"))
    }
}
