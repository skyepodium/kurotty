import Foundation
import XCTest
@testable import KurottyApp

final class TerminalClipboardConfirmationTests: XCTestCase {
    private let firstText = "first"
    private let secondText = "second"
    private let thirdText = "third"

    func testRequestArrivingWhileUnfocusedIsNotPresented() {
        var queue = TerminalClipboardConfirmationQueue()

        let submission = queue.submit(request(firstText), isFocused: false)

        XCTAssertEqual(submission, .deferred(supersededRequestCount: 0))
        XCTAssertFalse(queue.isPresenting)
        XCTAssertTrue(queue.hasPendingRequest)
    }

    func testHeldRequestIsPresentedOnceWhenFocusReturns() {
        var queue = TerminalClipboardConfirmationQueue()
        _ = queue.submit(request(firstText), isFocused: false)

        XCTAssertEqual(queue.focusDidChange(isFocused: true), request(firstText))
        // A second focus change must not present the same request again.
        XCTAssertNil(queue.focusDidChange(isFocused: true))
        XCTAssertFalse(queue.hasPendingRequest)
    }

    func testLosingFocusAgainBeforeReturningPresentsNothing() {
        var queue = TerminalClipboardConfirmationQueue()
        _ = queue.submit(request(firstText), isFocused: false)

        XCTAssertNil(queue.focusDidChange(isFocused: false))
        XCTAssertTrue(queue.hasPendingRequest)
    }

    /// The documented coalescing rule: the newest request wins and the older
    /// ones are dropped, so returning to the pane never means a stack of sheets.
    func testSeveralRequestsWhileAwayCoalesceToTheMostRecent() {
        var queue = TerminalClipboardConfirmationQueue()

        XCTAssertEqual(
            queue.submit(request(firstText), isFocused: false),
            .deferred(supersededRequestCount: 0)
        )
        XCTAssertEqual(
            queue.submit(request(secondText), isFocused: false),
            .deferred(supersededRequestCount: 1)
        )
        XCTAssertEqual(
            queue.submit(request(thirdText), isFocused: false),
            .deferred(supersededRequestCount: 2)
        )

        XCTAssertEqual(queue.focusDidChange(isFocused: true), request(thirdText))
        XCTAssertNil(queue.focusDidChange(isFocused: true))
    }

    func testDrainedQueueStartsCountingSupersededRequestsAgain() {
        var queue = TerminalClipboardConfirmationQueue()
        _ = queue.submit(request(firstText), isFocused: false)
        _ = queue.submit(request(secondText), isFocused: false)
        _ = queue.focusDidChange(isFocused: true)
        _ = queue.didFinishPresenting(isFocused: true)

        XCTAssertEqual(
            queue.submit(request(thirdText), isFocused: false),
            .deferred(supersededRequestCount: 0)
        )
    }

    func testTeardownWhileQueuedNeverPresents() {
        var queue = TerminalClipboardConfirmationQueue()
        _ = queue.submit(request(firstText), isFocused: false)

        queue.cancelPending()

        XCTAssertFalse(queue.hasPendingRequest)
        XCTAssertNil(queue.focusDidChange(isFocused: true))
        XCTAssertNil(queue.didFinishPresenting(isFocused: true))
    }

    func testFocusedRequestIsPresentedImmediately() {
        var queue = TerminalClipboardConfirmationQueue()

        XCTAssertEqual(queue.submit(request(firstText), isFocused: true), .present(request(firstText)))
        XCTAssertTrue(queue.isPresenting)
        XCTAssertFalse(queue.hasPendingRequest)
    }

    func testRequestArrivingWhileASheetIsUpWaitsForItToClose() {
        var queue = TerminalClipboardConfirmationQueue()
        _ = queue.submit(request(firstText), isFocused: true)

        XCTAssertEqual(
            queue.submit(request(secondText), isFocused: true),
            .deferred(supersededRequestCount: 0)
        )
        XCTAssertNil(queue.focusDidChange(isFocused: true))
        XCTAssertEqual(queue.didFinishPresenting(isFocused: true), request(secondText))
    }

    func testSheetClosingWhileUnfocusedHoldsTheNextRequest() {
        var queue = TerminalClipboardConfirmationQueue()
        _ = queue.submit(request(firstText), isFocused: true)
        _ = queue.submit(request(secondText), isFocused: true)

        XCTAssertNil(queue.didFinishPresenting(isFocused: false))
        XCTAssertTrue(queue.hasPendingRequest)
        XCTAssertEqual(queue.focusDidChange(isFocused: true), request(secondText))
    }

    func testAskEvaluationBecomesAConfirmationRequestCarryingTheDecodedWrite() throws {
        let payload = try XCTUnwrap(firstText.data(using: .utf8)).base64EncodedString()
        let evaluation = TerminalOSC52Policy(policy: .default)
            .evaluate(selection: "c", payload: payload, origin: .remote)

        let built = TerminalClipboardConfirmationRequest(evaluation: evaluation, base64Payload: payload)

        XCTAssertEqual(evaluation.decision, .ask)
        XCTAssertEqual(built?.selection, "c")
        XCTAssertEqual(built?.byteCount, firstText.utf8.count)
        XCTAssertEqual(built?.text, firstText)
    }

    func testAllowedAndDeniedEvaluationsDoNotBecomeConfirmationRequests() throws {
        let payload = try XCTUnwrap(firstText.data(using: .utf8)).base64EncodedString()
        let evaluator = TerminalOSC52Policy(policy: .default)

        let allowed = evaluator.evaluate(selection: "c", payload: payload, origin: .local)
        let denied = evaluator.evaluate(selection: "c", payload: "not base64!", origin: .remote)

        XCTAssertNil(TerminalClipboardConfirmationRequest(evaluation: allowed, base64Payload: payload))
        XCTAssertNil(TerminalClipboardConfirmationRequest(evaluation: denied, base64Payload: "not base64!"))
    }

    private func request(_ text: String) -> TerminalClipboardConfirmationRequest {
        TerminalClipboardConfirmationRequest(
            operation: .write,
            selection: "c",
            byteCount: text.utf8.count,
            text: text
        )
    }
}
