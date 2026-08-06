import Darwin
import Foundation
import XCTest
@testable import KurottyApp

final class TerminalOutputBackpressurePolicyTests: XCTestCase {
    private let policy = TerminalOutputBackpressurePolicy(
        highWaterMarkBytes: 1_000,
        lowWaterMarkBytes: 200,
        maximumBytesPerDrain: 500
    )

    func testReaderKeepsReadingBelowTheHighWaterMark() {
        XCTAssertEqual(policy.action(pendingBytes: 0, state: .reading), .none)
        XCTAssertEqual(policy.action(pendingBytes: 999, state: .reading), .none)
    }

    func testReaderSuspendsAtTheHighWaterMark() {
        XCTAssertEqual(policy.action(pendingBytes: 1_000, state: .reading), .suspendReader)
        XCTAssertEqual(policy.action(pendingBytes: 5_000, state: .reading), .suspendReader)
    }

    func testSuspendedReaderStaysSuspendedBetweenTheMarks() {
        for pendingBytes in [201, 500, 999, 1_000, 4_000] {
            XCTAssertEqual(
                policy.action(pendingBytes: pendingBytes, state: .suspended),
                .none,
                "pendingBytes=\(pendingBytes) must not thrash the reader back on"
            )
        }
    }

    func testSuspendedReaderResumesAtTheLowWaterMark() {
        XCTAssertEqual(policy.action(pendingBytes: 200, state: .suspended), .resumeReader)
        XCTAssertEqual(policy.action(pendingBytes: 0, state: .suspended), .resumeReader)
    }

    func testHysteresisSurvivesAFullSuspendResumeCycle() {
        var state = TerminalOutputBackpressurePolicy.ReaderState.reading
        state = policy.nextState(pendingBytes: 900, state: state)
        XCTAssertEqual(state, .reading)
        state = policy.nextState(pendingBytes: 1_100, state: state)
        XCTAssertEqual(state, .suspended)
        // The interesting case: draining back under the high mark is not enough.
        state = policy.nextState(pendingBytes: 900, state: state)
        XCTAssertEqual(state, .suspended)
        state = policy.nextState(pendingBytes: 150, state: state)
        XCTAssertEqual(state, .reading)
        state = policy.nextState(pendingBytes: 900, state: state)
        XCTAssertEqual(state, .reading)
    }

    func testLowWaterMarkIsClampedBelowTheHighWaterMark() {
        let degenerate = TerminalOutputBackpressurePolicy(
            highWaterMarkBytes: 100,
            lowWaterMarkBytes: 100,
            maximumBytesPerDrain: 10
        )
        XCTAssertLessThan(degenerate.lowWaterMarkBytes, degenerate.highWaterMarkBytes)
        // Equal marks would suspend and resume on the same byte count.
        XCTAssertEqual(degenerate.action(pendingBytes: 100, state: .reading), .suspendReader)
        XCTAssertEqual(degenerate.action(pendingBytes: 100, state: .suspended), .none)
    }

    func testNonPositiveMarksStillProduceAUsablePolicy() {
        let degenerate = TerminalOutputBackpressurePolicy(
            highWaterMarkBytes: 0,
            lowWaterMarkBytes: -5,
            maximumBytesPerDrain: 0
        )
        XCTAssertGreaterThan(degenerate.highWaterMarkBytes, 0)
        XCTAssertGreaterThanOrEqual(degenerate.lowWaterMarkBytes, 0)
        XCTAssertGreaterThan(degenerate.maximumBytesPerDrain, 0)
    }

    func testDrainLoopStopsAtThePerDrainByteCap() {
        XCTAssertTrue(policy.allowsAdditionalRead(pendingBytes: 0, bytesReadThisDrain: 499))
        XCTAssertFalse(policy.allowsAdditionalRead(pendingBytes: 0, bytesReadThisDrain: 500))
    }

    func testDrainLoopStopsAtTheHighWaterMarkEvenBelowTheCap() {
        XCTAssertTrue(policy.allowsAdditionalRead(pendingBytes: 999, bytesReadThisDrain: 0))
        XCTAssertFalse(policy.allowsAdditionalRead(pendingBytes: 1_000, bytesReadThisDrain: 0))
    }

    func testShippedPolicyResumesWellBelowItsSuspendPoint() {
        let shipped = TerminalOutputBackpressurePolicy.default
        XCTAssertLessThan(shipped.lowWaterMarkBytes, shipped.highWaterMarkBytes)
        XCTAssertLessThanOrEqual(shipped.maximumBytesPerDrain, shipped.highWaterMarkBytes)
        XCTAssertGreaterThan(shipped.highWaterMarkBytes, AppConstants.Shell.ptyReadBufferSizeBytes)
    }
}

final class TerminalPendingOutputBufferTests: XCTestCase {
    func testCompleteUTF8IsDecodedAndReleased() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 4_096)
        buffer.append(Data("héllo".utf8))

        XCTAssertEqual(buffer.takeDecodedText(), "héllo")
        XCTAssertEqual(buffer.pendingByteCount, 0)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.droppedByteCount, 0)
    }

    func testPartialTrailingScalarIsHeldBackUntilItCompletes() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 4_096)
        let scalarBytes = Array("한".utf8)
        XCTAssertEqual(scalarBytes.count, 3)

        buffer.append(Data("abcd".utf8) + Data(scalarBytes.prefix(2)))
        XCTAssertEqual(buffer.takeDecodedText(), "abcd")
        XCTAssertEqual(buffer.pendingByteCount, 2)

        buffer.append(Data(scalarBytes.suffix(1)))
        XCTAssertEqual(buffer.takeDecodedText(), "한")
        XCTAssertEqual(buffer.pendingByteCount, 0)
        XCTAssertEqual(buffer.droppedByteCount, 0)
    }

    func testTooFewBytesToDecideYieldsNothingRatherThanAPlaceholder() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 4_096)
        buffer.append(Data(Array("한".utf8).prefix(2)))

        XCTAssertNil(buffer.takeDecodedText())
        XCTAssertEqual(buffer.pendingByteCount, 2)
    }

    func testMalformedStreamAdvancesInsteadOfStalling() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 4_096)
        buffer.append(Data([0x41, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x42]))

        let text = buffer.takeDecodedText()
        XCTAssertNotNil(text)
        XCTAssertLessThan(buffer.pendingByteCount, 8)
    }

    func testOverflowDropsOldestBytesAndReportsTheLoss() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 8)
        buffer.append(Data("0123456789abcdef".utf8))

        XCTAssertEqual(buffer.pendingByteCount, 8)
        XCTAssertEqual(buffer.takeDecodedText(), "89abcdef")
        // Eight bytes were pushed out of the ring, and the count says so
        // instead of the loss being silent.
        XCTAssertEqual(buffer.droppedByteCount, 8)
    }

    func testRemoveAllResetsTheDecodeCursor() {
        var buffer = TerminalPendingOutputBuffer(byteLimit: 64)
        buffer.append(Data("stale".utf8))
        buffer.removeAll()

        XCTAssertTrue(buffer.isEmpty)
        buffer.append(Data("fresh".utf8))
        XCTAssertEqual(buffer.takeDecodedText(), "fresh")
        XCTAssertEqual(buffer.droppedByteCount, 0)
    }

    /// Sustained-output boundedness for the undecoded buffer: a reader that
    /// keeps up must never accumulate, no matter how much passes through.
    func testSustainedFirehoseKeepsTheBufferBoundedAndLosesNothing() {
        var buffer = TerminalPendingOutputBuffer(
            byteLimit: AppConstants.Shell.pendingOutputByteLimit
        )
        let chunk = Data(repeating: UInt8(ascii: "y"), count: AppConstants.Shell.ptyReadBufferSizeBytes)
        let chunkCount = 8_192
        var decodedByteCount = 0
        var peakPendingByteCount = 0

        for _ in 0..<chunkCount {
            buffer.append(chunk)
            peakPendingByteCount = max(peakPendingByteCount, buffer.pendingByteCount)
            decodedByteCount += buffer.takeDecodedText()?.utf8.count ?? 0
            peakPendingByteCount = max(peakPendingByteCount, buffer.pendingByteCount)
        }

        XCTAssertEqual(decodedByteCount, chunkCount * chunk.count)
        XCTAssertEqual(buffer.droppedByteCount, 0)
        XCTAssertEqual(buffer.pendingByteCount, 0)
        XCTAssertLessThanOrEqual(peakPendingByteCount, chunk.count)
    }

    /// The same firehose against a consumer that never reads: the ring is the
    /// backstop, so memory is capped and the loss is counted.
    func testStalledConsumerIsCappedByTheByteLimit() {
        let byteLimit = 64 * 1024
        var buffer = TerminalPendingOutputBuffer(byteLimit: byteLimit)
        let chunk = Data(repeating: UInt8(ascii: "y"), count: 8_192)
        let chunkCount = 4_096

        for _ in 0..<chunkCount {
            buffer.append(chunk)
            XCTAssertLessThanOrEqual(buffer.pendingByteCount, byteLimit)
        }

        XCTAssertEqual(buffer.pendingByteCount, byteLimit)
        XCTAssertEqual(buffer.droppedByteCount, 0, "nothing is dropped until the reader looks")
        XCTAssertEqual(buffer.takeDecodedText()?.utf8.count, byteLimit)
        XCTAssertEqual(buffer.droppedByteCount, chunkCount * chunk.count - byteLimit)
    }
}

final class TmuxBoundedOutputHistoryDiscardTests: XCTestCase {
    func testDiscardReleasesConsumedBytesWithoutMovingTheEndOffset() {
        var history = TmuxBoundedOutputHistory(byteLimit: 1_024)
        history.append(Data("abcdef".utf8))
        history.discard(before: 4)

        XCTAssertEqual(history.startOffset, 4)
        XCTAssertEqual(history.endOffset, 6)
        XCTAssertEqual(history.data, Data("ef".utf8))
        XCTAssertFalse(history.replay(after: 4).requiresFullReplay)
    }

    func testDiscardIsClampedAndIdempotent() {
        var history = TmuxBoundedOutputHistory(byteLimit: 1_024)
        history.append(Data("abc".utf8))
        history.discard(before: 99)
        history.discard(before: 99)

        XCTAssertEqual(history.startOffset, 3)
        XCTAssertEqual(history.endOffset, 3)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.storageChunkCount, 0)
    }

    func testDiscardBeforeTheStartOffsetIsANoOp() {
        var history = TmuxBoundedOutputHistory(byteLimit: 1_024)
        history.append(Data("abc".utf8))
        history.discard(before: 0)

        XCTAssertEqual(history.startOffset, 0)
        XCTAssertEqual(history.data, Data("abc".utf8))
    }

    func testFullyConsumedHistoryReleasesItsChunkStorage() {
        var history = TmuxBoundedOutputHistory(byteLimit: 1_024 * 1_024)
        for _ in 0..<512 {
            history.append(Data(repeating: 0x41, count: 8_192))
            history.discard(before: history.endOffset)
            // Without releasing consumed chunks the array would grow to the
            // compaction threshold and pin megabytes for a reader that is
            // fully caught up.
            XCTAssertEqual(history.storageChunkCount, 0)
        }
        XCTAssertTrue(history.isEmpty)
    }
}

#if os(macOS)
/// Exercises the live reader's flow control by handing it a pipe instead of a
/// PTY. The pipe's kernel buffer plays the same role: once the reader stops
/// draining, the writer stops making progress, which is the whole point of
/// suspending the read source.
final class DarwinPTYTerminalSessionBackpressureTests: XCTestCase {
    private var session: DarwinPTYTerminalSession?
    private var writeFileDescriptor: Int32 = -1

    override func setUp() {
        super.setUp()
        // Tearing down the reader closes the read end under the writer, and a
        // default SIGPIPE would take the test process with it.
        signal(SIGPIPE, SIG_IGN)
    }

    override func tearDown() {
        session?.stop()
        session = nil
        if writeFileDescriptor >= 0 {
            close(writeFileDescriptor)
            writeFileDescriptor = -1
        }
        super.tearDown()
    }

    func testFirehoseStallsTheWriterInsteadOfBufferingWithoutBound() throws {
        var descriptors: [Int32] = [-1, -1]
        try XCTSkipIf(pipe(&descriptors) != 0, "pipe(2) unavailable")
        let readFileDescriptor = descriptors[0]
        writeFileDescriptor = descriptors[1]
        // Non-blocking so the test thread measures how much the reader is
        // willing to take rather than parking in write(2) forever.
        _ = fcntl(writeFileDescriptor, F_SETFL, fcntl(writeFileDescriptor, F_GETFL, 0) | O_NONBLOCK)

        let session = DarwinPTYTerminalSession()
        self.session = session
        var deliveredByteCount = 0
        session.onOutput = { text in
            deliveredByteCount += text.utf8.count
        }
        session.attachOutputReaderForTesting(fileDescriptor: readFileDescriptor)

        // The test body occupies the main thread for the whole write loop, so
        // the delivery blocks the reader posts to the main queue cannot run.
        // That is exactly the pathological case: a renderer that has fallen
        // behind while the child keeps producing.
        let attemptedByteCount = 64 * 1024 * 1024
        let payload = [UInt8](repeating: UInt8(ascii: "y"), count: 16 * 1024)
        var writtenByteCount = 0
        var consecutiveStallCount = 0
        let deadline = Date().addingTimeInterval(5)
        while writtenByteCount < attemptedByteCount, consecutiveStallCount < 200, Date() < deadline {
            let written = payload.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(writeFileDescriptor, baseAddress, rawBuffer.count)
            }
            if written > 0 {
                writtenByteCount += written
                consecutiveStallCount = 0
                continue
            }
            guard written == -1, errno == EAGAIN || errno == EWOULDBLOCK else { break }
            consecutiveStallCount += 1
            usleep(1_000)
        }

        let stalled = session.outputBackpressureDiagnostics
        XCTAssertGreaterThanOrEqual(consecutiveStallCount, 200, "the writer must stop making progress")
        XCTAssertLessThan(
            writtenByteCount,
            4 * 1024 * 1024,
            "an uncapped reader would have absorbed the whole \(attemptedByteCount)-byte firehose"
        )
        XCTAssertTrue(stalled.isReaderSuspended)
        XCTAssertGreaterThan(stalled.suspendCount, 0)
        XCTAssertEqual(stalled.droppedByteCount, 0, "suspension must make dropping unnecessary")
        XCTAssertLessThanOrEqual(
            stalled.peakPendingByteCount,
            AppConstants.Shell.outputHighWaterMarkBytes + AppConstants.Shell.outputMaximumBytesPerDrain
        )

        // Releasing the main thread must lift the suspension, or the terminal
        // would be wedged rather than throttled.
        let resumeDeadline = Date().addingTimeInterval(10)
        while Date() < resumeDeadline, session.outputBackpressureDiagnostics.isReaderSuspended {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        let resumed = session.outputBackpressureDiagnostics
        XCTAssertFalse(resumed.isReaderSuspended, "the reader must come back once the surface catches up")
        XCTAssertGreaterThan(resumed.resumeCount, 0)
        XCTAssertGreaterThan(deliveredByteCount, 0)
        XCTAssertLessThanOrEqual(deliveredByteCount, writtenByteCount)
    }

    func testStoppingASuspendedReaderDoesNotWedgeOrTrap() throws {
        var descriptors: [Int32] = [-1, -1]
        try XCTSkipIf(pipe(&descriptors) != 0, "pipe(2) unavailable")
        writeFileDescriptor = descriptors[1]
        _ = fcntl(writeFileDescriptor, F_SETFL, fcntl(writeFileDescriptor, F_GETFL, 0) | O_NONBLOCK)

        let session = DarwinPTYTerminalSession()
        self.session = session
        session.attachOutputReaderForTesting(fileDescriptor: descriptors[0])

        let payload = [UInt8](repeating: UInt8(ascii: "y"), count: 16 * 1024)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !session.outputBackpressureDiagnostics.isReaderSuspended {
            let written = payload.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(writeFileDescriptor, baseAddress, rawBuffer.count)
            }
            if written == -1 {
                usleep(1_000)
            }
        }
        XCTAssertTrue(session.outputBackpressureDiagnostics.isReaderSuspended)

        // A suspended dispatch source never runs its cancel handler and traps on
        // deallocation, so stop() has to balance the suspension first.
        session.stop()
        self.session = nil
    }
}
#endif
