import Foundation
import XCTest
@testable import KurottyApp

final class AIAgentActionApprovalTests: XCTestCase {
    func testDefaultPolicyAllowsRedactedContextExportAsksForAgentTextAndDeniesUnsafeURL() throws {
        let evaluator = AIAgentActionApprovalEvaluator()

        let allowed = evaluator.evaluate(
            .exportContext(id: "export-redacted", rawContext: "status: ok", includesRawOutput: false)
        )
        let asked = evaluator.evaluate(.sendText(id: "send", text: "rm -rf /tmp/example"))
        let denied = evaluator.evaluate(
            .openFileURL(id: "url", url: try XCTUnwrap(URL(string: "ssh://example.com/repo")))
        )

        XCTAssertEqual(allowed.decision, .allow)
        XCTAssertEqual(allowed.reason, "redacted context export allowed by policy")
        XCTAssertEqual(asked.decision, .ask)
        XCTAssertEqual(asked.reason, "agent terminal text requires explicit approval")
        XCTAssertEqual(denied.decision, .deny)
        XCTAssertEqual(denied.reason, "URL open denied by terminal security policy")
    }

    func testPolicyBackedActionsAskForPasteAndAllowedFileURLByDefault() {
        let evaluator = AIAgentActionApprovalEvaluator()

        let paste = evaluator.evaluate(.pasteText(id: "paste", text: "echo hi"))
        let file = evaluator.evaluate(.openFileURL(id: "file", url: URL(fileURLWithPath: "/tmp/report.txt")))

        XCTAssertEqual(paste.decision, .ask)
        XCTAssertEqual(paste.reason, "clipboard paste requires explicit approval")
        XCTAssertEqual(file.decision, .ask)
        XCTAssertEqual(file.reason, "URL open requires explicit approval")
    }

    func testRawContextExportRequiresRedactionAndApproval() {
        let evaluator = AIAgentActionApprovalEvaluator()

        let missingRedaction = evaluator.evaluate(
            .exportContext(
                id: "raw-without-redaction",
                rawContext: "Authorization: Bearer bearer-token-abcdefghijklmnopqrstuvwxyz",
                includesRawOutput: true,
                secretRedactionEnabled: false
            )
        )
        let needsApproval = evaluator.evaluate(
            .exportContext(
                id: "raw-with-redaction",
                rawContext: "Authorization: Bearer bearer-token-abcdefghijklmnopqrstuvwxyz",
                includesRawOutput: true,
                secretRedactionEnabled: true
            )
        )
        let approved = evaluator.approve(needsApproval)

        XCTAssertEqual(missingRedaction.decision, .deny)
        XCTAssertEqual(missingRedaction.reason, "raw context export requires secret redaction")
        XCTAssertEqual(needsApproval.decision, .ask)
        XCTAssertEqual(needsApproval.reason, "raw context export requires explicit approval")
        XCTAssertEqual(approved.decision, .allow)
        XCTAssertEqual(approved.reason, "approved: raw context export requires explicit approval")
    }

    func testDescriptionsAndAuditPreviewsRedactAndBoundRawPayloads() {
        let rawToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let action = AIAgentActionRequest.sendText(
            id: "send-secret",
            text: "deploy token=\(rawToken) " + String(repeating: "x", count: 200)
        )
        let result = AIAgentActionApprovalEvaluator(maxPreviewLength: 48).evaluate(action)

        XCTAssertFalse(String(describing: action).contains(rawToken))
        XCTAssertFalse(result.redactedPreview.contains(rawToken))
        XCTAssertTrue(result.redactedPreview.contains("token=[REDACTED_SECRET]"))
        XCTAssertLessThanOrEqual(result.redactedPreview.count, 48)
        XCTAssertTrue(String(describing: action).contains("sendText(id: send-secret"))
    }

    func testAuditRecordCapturesSafeMetadataWithInjectableTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 123)
        let evaluator = AIAgentActionApprovalEvaluator(
            maxPreviewLength: 80,
            now: { timestamp }
        )
        let result = evaluator.evaluate(
            .pasteText(id: "paste-secret", text: "password=hunter2")
        )

        let audit = result.auditRecord()

        XCTAssertEqual(audit.actionID, "paste-secret")
        XCTAssertEqual(audit.decision, .ask)
        XCTAssertEqual(audit.reason, "clipboard paste requires explicit approval")
        XCTAssertEqual(audit.redactedPreview, "password=[REDACTED_SECRET]")
        XCTAssertEqual(audit.timestamp, timestamp)
        XCTAssertFalse(String(describing: audit).contains("hunter2"))
    }

    func testAuditRecordCarriesApprovalContextWithoutLeakingRawPayload() {
        let metadata = AIAgentActionApprovalMetadata(
            actor: "planner-agent",
            targetPaneID: "pane-1",
            targetWorkspaceID: "workspace-7",
            cwd: "/Users/example/project",
            capability: "send-text",
            persistenceScope: .session,
            contextSummary: "selected command span"
        )
        let evaluator = AIAgentActionApprovalEvaluator(maxPreviewLength: 80)
        let result = evaluator.evaluate(
            .sendText(
                id: "send-with-context",
                text: "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                metadata: metadata
            )
        )

        let audit = result.auditRecord()

        XCTAssertEqual(result.metadata, metadata)
        XCTAssertEqual(audit.metadata, metadata)
        XCTAssertEqual(audit.metadata.actor, "planner-agent")
        XCTAssertEqual(audit.metadata.targetPaneID, "pane-1")
        XCTAssertEqual(audit.metadata.targetWorkspaceID, "workspace-7")
        XCTAssertEqual(audit.metadata.cwd, "/Users/example/project")
        XCTAssertEqual(audit.metadata.capability, "send-text")
        XCTAssertEqual(audit.metadata.persistenceScope, .session)
        XCTAssertEqual(audit.metadata.contextSummary, "selected command span")
        XCTAssertFalse(audit.redactedPreview.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(String(describing: audit).contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }
}
