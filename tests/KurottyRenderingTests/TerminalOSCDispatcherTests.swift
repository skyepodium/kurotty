import Foundation
import XCTest
@testable import KurottyApp

final class TerminalOSCDispatcherTests: XCTestCase {
    func testOSC52AcceptedWriteRoutesToPolicyEvaluation() throws {
        var dispatcher = TerminalOSCDispatcher(osc52Policy: TerminalOSC52Policy(policy: .default))
        let payload = try XCTUnwrap("hello".data(using: .utf8)).base64EncodedString()

        let event = dispatcher.dispatch("52;c;\(payload)", origin: .local)

        guard case .osc52(let evaluation) = event else {
            return XCTFail("Expected OSC52 evaluation, got \(event)")
        }
        XCTAssertEqual(evaluation.decision, .allow)
        XCTAssertEqual(evaluation.operation, .write)
        XCTAssertEqual(evaluation.securityOperation, .osc52Write)
        XCTAssertEqual(evaluation.metadata.selection, "c")
        XCTAssertEqual(evaluation.metadata.origin, .local)
        XCTAssertEqual(evaluation.metadata.byteCount, 5)
        XCTAssertNil(evaluation.rejectionReason)
    }

    func testOSC52DeniedReadRoutesToPolicyEvaluation() {
        var dispatcher = TerminalOSCDispatcher(osc52Policy: TerminalOSC52Policy(policy: .default))

        let event = dispatcher.dispatch("52;c;?", origin: .remote)

        guard case .osc52(let evaluation) = event else {
            return XCTFail("Expected OSC52 evaluation, got \(event)")
        }
        XCTAssertEqual(evaluation.decision, .deny)
        XCTAssertEqual(evaluation.operation, .read)
        XCTAssertEqual(evaluation.securityOperation, .osc52Read)
        XCTAssertEqual(evaluation.metadata.selection, "c")
        XCTAssertEqual(evaluation.metadata.origin, .remote)
        XCTAssertEqual(evaluation.metadata.byteCount, 0)
        XCTAssertNil(evaluation.rejectionReason)
    }

    func testOSC52OversizedPayloadRoutesToPolicyEvaluationWithoutClipboardMutation() throws {
        var dispatcher = TerminalOSCDispatcher(
            osc52Policy: TerminalOSC52Policy(policy: .default, maxDecodedBytes: 4)
        )
        let payload = try XCTUnwrap("hello".data(using: .utf8)).base64EncodedString()

        let event = dispatcher.dispatch("52;c;\(payload)", origin: .local)

        guard case .osc52(let evaluation) = event else {
            return XCTFail("Expected OSC52 evaluation, got \(event)")
        }
        XCTAssertEqual(evaluation.decision, .deny)
        XCTAssertEqual(evaluation.operation, .write)
        XCTAssertEqual(evaluation.securityOperation, .osc52Write)
        XCTAssertEqual(evaluation.metadata.byteCount, 5)
        XCTAssertEqual(evaluation.rejectionReason, .payloadTooLarge)
    }

    func testOSC7RoutesToShellIntegration() {
        var dispatcher = TerminalOSCDispatcher(osc52Policy: TerminalOSC52Policy(policy: .default))

        let event = dispatcher.dispatch("7;file://localhost/Users/skye/Project%20One", origin: .local)

        XCTAssertEqual(event, .shellIntegration(.workingDirectoryChanged("/Users/skye/Project One")))
        XCTAssertEqual(dispatcher.shellIntegration.currentWorkingDirectoryCandidate, "/Users/skye/Project One")
    }

    func testOSC133RoutesToShellIntegration() {
        var dispatcher = TerminalOSCDispatcher(osc52Policy: TerminalOSC52Policy(policy: .default))

        let event = dispatcher.dispatch("133;A", origin: .local)

        XCTAssertEqual(event, .shellIntegration(.promptStart))
        XCTAssertEqual(dispatcher.shellIntegration.currentBoundary, .promptStart)
        XCTAssertEqual(dispatcher.shellIntegration.sessionEvidence.observedPassiveOSCSequences, [.osc133])
    }

    func testOSC133CommandEndRoutesCompletionContext() {
        var dispatcher = TerminalOSCDispatcher(osc52Policy: TerminalOSC52Policy(policy: .default))

        _ = dispatcher.dispatch("133;B", origin: .local)
        dispatcher.shellIntegration.setActiveCommandText("swift test")
        _ = dispatcher.dispatch("133;C", origin: .local)
        let event = dispatcher.dispatch("133;D;0", origin: .local)

        guard case .shellIntegration(.commandEnd(let context)) = event else {
            return XCTFail("Expected command completion context, got \(event)")
        }
        XCTAssertEqual(context.commandText, "swift test")
        XCTAssertEqual(context.exitCode, 0)
        XCTAssertEqual(context.span.reference.spanID, 1)
    }

    func testUnknownOSCIsIgnored() {
        var dispatcher = TerminalOSCDispatcher(
            osc52Policy: TerminalOSC52Policy(policy: .default),
            shellIntegration: TerminalShellIntegration(currentWorkingDirectoryCandidate: "/before")
        )
        let shellIntegrationSnapshot = dispatcher.shellIntegration

        let event = dispatcher.dispatch("999;payload", origin: .local)

        XCTAssertEqual(event, .ignored)
        XCTAssertEqual(dispatcher.shellIntegration, shellIntegrationSnapshot)
    }
}
