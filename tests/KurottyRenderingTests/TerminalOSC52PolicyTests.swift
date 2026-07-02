import Foundation
import XCTest
@testable import KurottyApp

final class TerminalOSC52PolicyTests: XCTestCase {
    func testLocalBase64WriteIsAllowedWithMetadataButNoPreviewByDefault() throws {
        let evaluator = TerminalOSC52Policy(policy: .default)
        let payload = try XCTUnwrap("hello".data(using: .utf8)).base64EncodedString()

        let result = evaluator.evaluate(selection: "c", payload: payload, origin: .local)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertEqual(result.operation, .write)
        XCTAssertEqual(result.securityOperation, .osc52Write)
        XCTAssertEqual(result.metadata.selection, "c")
        XCTAssertEqual(result.metadata.origin, .local)
        XCTAssertEqual(result.metadata.byteCount, 5)
        XCTAssertNil(result.metadata.decodedPreview)
        XCTAssertNil(result.rejectionReason)
    }

    func testRemoteBase64WriteAsks() throws {
        let evaluator = TerminalOSC52Policy(policy: .default)
        let payload = try XCTUnwrap("hello".data(using: .utf8)).base64EncodedString()

        let result = evaluator.evaluate(selection: "c", payload: payload, origin: .remote)

        XCTAssertEqual(result.decision, .ask)
        XCTAssertEqual(result.operation, .write)
        XCTAssertEqual(result.securityOperation, .osc52Write)
        XCTAssertEqual(result.metadata.origin, .remote)
        XCTAssertEqual(result.metadata.byteCount, 5)
        XCTAssertNil(result.rejectionReason)
    }

    func testRemoteReadRequestIsDenied() {
        let evaluator = TerminalOSC52Policy(policy: .default)

        let questionResult = evaluator.evaluate(selection: "c", payload: "?", origin: .remote)

        XCTAssertEqual(questionResult.decision, .deny)
        XCTAssertEqual(questionResult.operation, .read)
        XCTAssertEqual(questionResult.securityOperation, .osc52Read)
        XCTAssertEqual(questionResult.metadata.byteCount, 0)
        XCTAssertNil(questionResult.rejectionReason)
    }

    func testEmptyPayloadIsZeroByteWriteNotRead() {
        let evaluator = TerminalOSC52Policy(policy: .default)

        let result = evaluator.evaluate(selection: "c", payload: "", origin: .local)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertEqual(result.operation, .write)
        XCTAssertEqual(result.securityOperation, .osc52Write)
        XCTAssertEqual(result.metadata.byteCount, 0)
        XCTAssertNil(result.rejectionReason)
    }

    func testInvalidBase64IsDeniedAsInvalidWithoutDecodedPreview() {
        let evaluator = TerminalOSC52Policy(policy: .default)

        let result = evaluator.evaluate(selection: "c", payload: "not base64!!", origin: .local)

        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.operation, .invalid)
        XCTAssertEqual(result.securityOperation, .osc52Write)
        XCTAssertNil(result.metadata.byteCount)
        XCTAssertNil(result.metadata.decodedPreview)
        XCTAssertEqual(result.rejectionReason, .invalidPayload)
    }

    func testPayloadTooLargeIsDeniedWithoutRawPayloadLeak() throws {
        let evaluator = TerminalOSC52Policy(policy: .default, maxDecodedBytes: 4)
        let rawPayload = "sensitive clipboard value"
        let payload = try XCTUnwrap(rawPayload.data(using: .utf8)).base64EncodedString()

        let result = evaluator.evaluate(selection: "c", payload: payload, origin: .local)

        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.operation, .write)
        XCTAssertEqual(result.securityOperation, .osc52Write)
        XCTAssertEqual(result.metadata.byteCount, rawPayload.utf8.count)
        XCTAssertNil(result.metadata.decodedPreview)
        XCTAssertEqual(result.rejectionReason, .payloadTooLarge)
        XCTAssertFalse(String(describing: result).contains(rawPayload))
        XCTAssertFalse(String(describing: result).contains(payload))
    }
}
