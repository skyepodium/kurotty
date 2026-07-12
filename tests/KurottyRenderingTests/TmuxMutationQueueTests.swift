import Foundation
import XCTest
@testable import KurottyApp

final class TmuxMutationQueueTests: XCTestCase {
    func testDefaultLimitsMatchBackpressureContract() {
        let limits = TmuxMutationQueue.Limits.default

        XCTAssertEqual(limits.maximumInputByteCount, 4 * 1024 * 1024)
        XCTAssertEqual(limits.maximumPayloadByteCount, 8 * 1024 * 1024)
        XCTAssertEqual(limits.maximumStructuralCount, 1_024)
        XCTAssertEqual(limits.maximumResizeKeyCount, 512)
        XCTAssertEqual(limits.inputChunkByteCount, 16 * 1024)
    }

    func testOverflowErrorsDescribeLimitsAndAttempts() {
        XCTAssertEqual(
            TmuxMutationQueue.EnqueueError.inputByteLimitExceeded(limit: 4, attempted: 5).errorDescription,
            "tmux input backlog exceeded 4 bytes (attempted 5)"
        )
        XCTAssertEqual(
            TmuxMutationQueue.EnqueueError.payloadByteLimitExceeded(limit: 8, attempted: 9).errorDescription,
            "tmux mutation backlog exceeded 8 bytes (attempted 9)"
        )
        XCTAssertEqual(
            TmuxMutationQueue.EnqueueError.structuralCountLimitExceeded(limit: 1, attempted: 2).errorDescription,
            "tmux structural backlog exceeded 1 requests (attempted 2)"
        )
        XCTAssertEqual(
            TmuxMutationQueue.EnqueueError.resizeKeyLimitExceeded(limit: 1, attempted: 2).errorDescription,
            "tmux resize backlog exceeded 1 targets (attempted 2)"
        )
    }

    func testTenThousandKeysBatchIntoOneLogicalInputAndPreserveBytes() throws {
        var queue = TmuxMutationQueue()
        var expected = Data()
        expected.reserveCapacity(10_000)

        for index in 0..<10_000 {
            let byte = UInt8(index % 251)
            expected.append(byte)
            try queue.enqueueInput(paneID: "%0", data: Data([byte]))
        }

        XCTAssertEqual(queue.metrics.pendingNormalEntryCount, 1)
        XCTAssertEqual(queue.metrics.pendingInputByteCount, expected.count)
        let mutations = popAll(from: &queue)
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations, [.sendKeys(paneID: "%0", data: expected)])
        XCTAssertTrue(queue.isEmpty)
    }

    func testLargePasteIsChunkedWithoutCrossingStructuralBoundary() throws {
        var queue = TmuxMutationQueue()
        let firstHalf = Data((0..<20_000).map { UInt8($0 % 251) })
        let secondHalf = Data((20_000..<40_000).map { UInt8($0 % 251) })
        let expectedPaste = firstHalf + secondHalf
        let splitCommand = Data("split-window -h\n".utf8)
        let trailingInput = Data("after-split".utf8)

        try queue.enqueueInput(paneID: "%0", data: firstHalf)
        try queue.enqueueInput(paneID: "%0", data: secondHalf)
        try queue.enqueueStructural(command: splitCommand)
        try queue.enqueueInput(paneID: "%0", data: trailingInput)

        XCTAssertEqual(queue.metrics.pendingNormalEntryCount, 3)
        let mutations = popAll(from: &queue)
        let splitIndex = try XCTUnwrap(mutations.firstIndex(of: .structural(command: splitCommand)))
        let inputBeforeSplit = mutations[..<splitIndex].compactMap { mutation -> Data? in
            guard case let .sendKeys(paneID, data) = mutation, paneID == "%0" else { return nil }
            return data
        }
        XCTAssertEqual(inputBeforeSplit.count, 3)
        XCTAssertTrue(inputBeforeSplit.allSatisfy { $0.count <= 16 * 1024 })
        XCTAssertEqual(inputBeforeSplit.reduce(into: Data(), { $0.append($1) }), expectedPaste)
        XCTAssertEqual(Array(mutations[(splitIndex + 1)...]), [
            .sendKeys(paneID: "%0", data: trailingInput),
        ])
    }

    func testTenThousandResizesKeepOnlyLatestValuePerKey() throws {
        var queue = TmuxMutationQueue()

        for index in 0..<10_000 {
            try queue.enqueuePaneResize(paneID: "%0", columns: index + 1, rows: index + 2)
            try queue.enqueueClientResize(windowID: "@0", columns: index + 3, rows: index + 4)
        }

        XCTAssertEqual(queue.metrics.pendingResizeKeyCount, 2)
        XCTAssertEqual(queue.metrics.resizeStorageSlotCount, 2)
        XCTAssertEqual(popAll(from: &queue), [
            .resizePane(paneID: "%0", columns: 10_000, rows: 10_001),
            .resizeClient(windowID: "@0", columns: 10_002, rows: 10_003),
        ])
    }

    func testMultipleResizeKeysRetainInsertionOrderAndLatestValues() throws {
        var queue = TmuxMutationQueue()

        try queue.enqueuePaneResize(paneID: "%0", columns: 80, rows: 24)
        try queue.enqueueClientResize(windowID: "@0", columns: 100, rows: 30)
        try queue.enqueuePaneResize(paneID: "%1", columns: 60, rows: 20)
        try queue.enqueuePaneResize(paneID: "%0", columns: 90, rows: 28)
        try queue.enqueueClientResize(windowID: "@0", columns: 110, rows: 32)

        XCTAssertEqual(popAll(from: &queue), [
            .resizePane(paneID: "%0", columns: 90, rows: 28),
            .resizeClient(windowID: "@0", columns: 110, rows: 32),
            .resizePane(paneID: "%1", columns: 60, rows: 20),
        ])
    }

    func testInputStructuralAndResizeInterleaveWithoutBreakingInputOrder() throws {
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 64,
            maximumPayloadByteCount: 1_024,
            maximumStructuralCount: 16,
            maximumResizeKeyCount: 16,
            inputChunkByteCount: 2,
            normalPopsBeforeResize: 2
        )
        var queue = TmuxMutationQueue(limits: limits)
        let structural = Data("select-pane -t '%1'\n".utf8)

        try queue.enqueuePaneResize(paneID: "%0", columns: 90, rows: 30)
        try queue.enqueueInput(paneID: "%0", data: Data("aabbcc".utf8))
        try queue.enqueueStructural(command: structural)
        try queue.enqueueInput(paneID: "%1", data: Data("dd".utf8))

        XCTAssertEqual(popAll(from: &queue), [
            .sendKeys(paneID: "%0", data: Data("aa".utf8)),
            .sendKeys(paneID: "%0", data: Data("bb".utf8)),
            .resizePane(paneID: "%0", columns: 90, rows: 30),
            .sendKeys(paneID: "%0", data: Data("cc".utf8)),
            .structural(command: structural),
            .sendKeys(paneID: "%1", data: Data("dd".utf8)),
        ])
    }

    func testOverflowErrorsAreExplicitAndLeaveQueuedInputUntouched() throws {
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 4,
            maximumPayloadByteCount: 8,
            maximumStructuralCount: 1,
            maximumResizeKeyCount: 1,
            inputChunkByteCount: 2
        )
        var queue = TmuxMutationQueue(limits: limits)
        try queue.enqueueInput(paneID: "%0", data: Data("1234".utf8))
        let metricsBeforeFailure = queue.metrics

        XCTAssertThrowsError(try queue.enqueueInput(paneID: "%0", data: Data("5".utf8))) { error in
            XCTAssertEqual(
                error as? TmuxMutationQueue.EnqueueError,
                .inputByteLimitExceeded(limit: 4, attempted: 5)
            )
        }
        XCTAssertEqual(queue.metrics, metricsBeforeFailure)

        try queue.enqueueStructural(command: Data("abcd".utf8))
        XCTAssertThrowsError(try queue.enqueueStructural(command: Data())) { error in
            XCTAssertEqual(
                error as? TmuxMutationQueue.EnqueueError,
                .structuralCountLimitExceeded(limit: 1, attempted: 2)
            )
        }
        XCTAssertEqual(popAll(from: &queue), [
            .sendKeys(paneID: "%0", data: Data("12".utf8)),
            .sendKeys(paneID: "%0", data: Data("34".utf8)),
            .structural(command: Data("abcd".utf8)),
        ])
    }

    func testPayloadAndResizeKeyBoundsReportDistinctErrors() throws {
        let payloadLimits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 16,
            maximumPayloadByteCount: 4,
            maximumStructuralCount: 4,
            maximumResizeKeyCount: 4,
            inputChunkByteCount: 4
        )
        var payloadQueue = TmuxMutationQueue(limits: payloadLimits)
        try payloadQueue.enqueueInput(paneID: "%0", data: Data("1234".utf8))
        XCTAssertThrowsError(try payloadQueue.enqueueStructural(command: Data([0]))) { error in
            XCTAssertEqual(
                error as? TmuxMutationQueue.EnqueueError,
                .payloadByteLimitExceeded(limit: 4, attempted: 5)
            )
        }

        let resizeLimits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 16,
            maximumPayloadByteCount: 1_024,
            maximumStructuralCount: 4,
            maximumResizeKeyCount: 1,
            inputChunkByteCount: 4
        )
        var resizeQueue = TmuxMutationQueue(limits: resizeLimits)
        try resizeQueue.enqueuePaneResize(paneID: "%0", columns: 80, rows: 24)
        try resizeQueue.enqueuePaneResize(paneID: "%0", columns: 90, rows: 30)
        XCTAssertThrowsError(try resizeQueue.enqueueClientResize(windowID: "@0", columns: 90, rows: 30)) { error in
            XCTAssertEqual(
                error as? TmuxMutationQueue.EnqueueError,
                .resizeKeyLimitExceeded(limit: 1, attempted: 2)
            )
        }
        XCTAssertEqual(popAll(from: &resizeQueue), [
            .resizePane(paneID: "%0", columns: 90, rows: 30),
        ])
    }

    func testDetachAlwaysAdmitsClearsStaleWorkAndRejectsNewMutationsUntilReset() throws {
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 1,
            maximumPayloadByteCount: 1,
            maximumStructuralCount: 0,
            maximumResizeKeyCount: 0,
            inputChunkByteCount: 1
        )
        var queue = TmuxMutationQueue(limits: limits)
        try queue.enqueueInput(paneID: "%0", data: Data([0]))

        queue.enqueueDetach()

        XCTAssertEqual(queue.metrics.pendingInputByteCount, 0)
        XCTAssertEqual(queue.metrics.pendingPayloadByteCount, 0)
        XCTAssertEqual(queue.metrics.pendingNormalEntryCount, 0)
        XCTAssertTrue(queue.metrics.isDetaching)
        XCTAssertEqual(queue.popFirst(), .detachClient)
        XCTAssertNil(queue.popFirst())
        queue.enqueueDetach()
        XCTAssertNil(queue.popFirst(), "detach admission is idempotent while detaching")
        XCTAssertThrowsError(try queue.enqueueInput(paneID: "%0", data: Data([1]))) { error in
            XCTAssertEqual(error as? TmuxMutationQueue.EnqueueError, .detaching)
        }

        queue.reset()
        try queue.enqueueInput(paneID: "%0", data: Data([2]))
        XCTAssertEqual(queue.popFirst(), .sendKeys(paneID: "%0", data: Data([2])))
    }

    func testHeadIndexStorageCompactsWithoutPerPopArrayShifts() throws {
        let limits = TmuxMutationQueue.Limits(
            maximumInputByteCount: 1,
            maximumPayloadByteCount: 2_000,
            maximumStructuralCount: 1_000,
            maximumResizeKeyCount: 1,
            inputChunkByteCount: 1
        )
        var queue = TmuxMutationQueue(limits: limits)
        for index in 0..<700 {
            try queue.enqueueStructural(command: Data([UInt8(index % 251)]))
        }
        XCTAssertEqual(queue.metrics.normalStorageSlotCount, 700)

        var firstValues: [UInt8] = []
        for _ in 0..<400 {
            guard case let .structural(command)? = queue.popFirst() else {
                return XCTFail("missing structural mutation")
            }
            firstValues.append(command[command.startIndex])
        }

        XCTAssertEqual(firstValues, (0..<400).map { UInt8($0 % 251) })
        XCTAssertEqual(queue.metrics.pendingNormalEntryCount, 300)
        XCTAssertLessThanOrEqual(queue.metrics.normalStorageSlotCount, 350)
        XCTAssertEqual(popAll(from: &queue).count, 300)
        XCTAssertEqual(queue.metrics.normalStorageSlotCount, 0)
    }

    private func popAll(from queue: inout TmuxMutationQueue) -> [TmuxMutationQueue.Mutation] {
        var mutations: [TmuxMutationQueue.Mutation] = []
        while let mutation = queue.popFirst() {
            mutations.append(mutation)
        }
        return mutations
    }
}
