import Foundation
import XCTest
@testable import KurottyApp

final class AIAgentActionApprovalTests: XCTestCase {
    func testActionRequestExposesStableBackendDispatchKind() throws {
        XCTAssertEqual(AIAgentActionRequest.sendText(id: "send", text: "echo ok").kind, .sendText)
        XCTAssertEqual(AIAgentActionRequest.pasteText(id: "paste", text: "echo ok").kind, .pasteText)
        XCTAssertEqual(
            AIAgentActionRequest.exportContext(id: "export", rawContext: "context", includesRawOutput: false).kind,
            .exportContext
        )
        XCTAssertEqual(
            AIAgentActionRequest.openFileURL(
                id: "file",
                url: URL(fileURLWithPath: "/tmp/report.txt")
            ).kind,
            .openFileURL
        )
    }

    func testDispatcherDoesNotInvokeBackendHandlerUntilAskResultIsApproved() {
        var sentText: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(sendText: { text, _ in sentText.append(text) })
        )
        let action = AIAgentActionRequest.sendText(id: "send", text: "echo ok")

        let pending = dispatcher.dispatch(action)
        XCTAssertEqual(pending.status, .requiresApproval)
        XCTAssertEqual(pending.audit.decision, .ask)
        XCTAssertEqual(pending.approval.actionKind, .sendText)
        XCTAssertTrue(sentText.isEmpty)

        let approved = dispatcher.dispatch(action, approval: dispatcher.approve(pending.approval))
        XCTAssertEqual(approved.status, .dispatched)
        XCTAssertEqual(approved.audit.decision, .allow)
        XCTAssertEqual(sentText, ["echo ok"])
    }

    func testDispatcherRejectsMismatchedApprovalWithoutInvokingBackendHandler() {
        var sentText: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(sendText: { text, _ in sentText.append(text) })
        )
        let approval = dispatcher.approve(
            dispatcher.dispatch(AIAgentActionRequest.sendText(id: "first", text: "echo first")).approval
        )

        let result = dispatcher.dispatch(
            AIAgentActionRequest.sendText(id: "second", text: "echo second"),
            approval: approval
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "approval result does not match action request")
        XCTAssertTrue(sentText.isEmpty)
    }

    func testDispatcherRejectsMismatchedApprovalKindWithoutInvokingBackendHandler() {
        var pastedText: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(pasteText: { text, _, _ in pastedText.append(text) })
        )
        let approval = dispatcher.approve(
            dispatcher.dispatch(AIAgentActionRequest.sendText(id: "shared", text: "echo first")).approval
        )

        let result = dispatcher.dispatch(
            AIAgentActionRequest.pasteText(id: "shared", text: "echo second"),
            approval: approval
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "approval result kind does not match action request")
        XCTAssertTrue(pastedText.isEmpty)
    }

    func testDispatcherRejectsSameKindChangedPayloadWithoutInvokingBackendHandler() {
        var sentText: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(sendText: { text, _ in sentText.append(text) })
        )
        let approval = dispatcher.approve(
            dispatcher.dispatch(AIAgentActionRequest.sendText(id: "shared", text: "echo first")).approval
        )

        let result = dispatcher.dispatch(
            AIAgentActionRequest.sendText(id: "shared", text: "echo second"),
            approval: approval
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "approval result fingerprint does not match action request")
        XCTAssertTrue(sentText.isEmpty)
    }

    func testDialogApprovalRejectsSameIDSameKindChangedPayloadWithoutInvokingBackendHandler() {
        var sentText: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(sendText: { text, _ in sentText.append(text) })
        )
        let pending = dispatcher.dispatch(AIAgentActionRequest.sendText(id: "shared", text: "echo safe"))
        let dialogDecision = AIAgentActionApprovalDialogFlow(result: pending.approval).approve()

        let result = dispatcher.dispatch(
            AIAgentActionRequest.sendText(id: "shared", text: "echo changed"),
            dialogDecision: dialogDecision
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "approval result fingerprint does not match action request")
        XCTAssertTrue(sentText.isEmpty)
    }

    func testDispatcherRejectsChangedRawExportContextWithoutInvokingBackendHandler() {
        var exportedContexts: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(exportContext: { context, _ in exportedContexts.append(context) })
        )
        let approval = dispatcher.approve(
            dispatcher.dispatch(
                AIAgentActionRequest.exportContext(
                    id: "export",
                    rawContext: "raw command output: first",
                    includesRawOutput: true,
                    secretRedactionEnabled: true
                )
            ).approval
        )

        let result = dispatcher.dispatch(
            AIAgentActionRequest.exportContext(
                id: "export",
                rawContext: "raw command output: second",
                includesRawOutput: true,
                secretRedactionEnabled: true
            ),
            approval: approval
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "approval result fingerprint does not match action request")
        XCTAssertTrue(exportedContexts.isEmpty)
    }

    func testDispatcherRejectsChangedRawExportSecurityFlagsWithoutInvokingBackendHandler() {
        var exportedContexts: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(exportContext: { context, _ in exportedContexts.append(context) })
        )
        let approval = dispatcher.approve(
            dispatcher.dispatch(
                AIAgentActionRequest.exportContext(
                    id: "export-flags",
                    rawContext: "raw command output",
                    includesRawOutput: true,
                    secretRedactionEnabled: true
                )
            ).approval
        )

        let result = dispatcher.dispatch(
            AIAgentActionRequest.exportContext(
                id: "export-flags",
                rawContext: "raw command output",
                includesRawOutput: true,
                secretRedactionEnabled: false
            ),
            approval: approval
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "current action request is denied by policy")
        XCTAssertTrue(exportedContexts.isEmpty)
    }

    func testDispatcherRejectsUnsafeURLDespiteSameKindApproval() throws {
        var openedURLs: [URL] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(openFileURL: { url, _ in openedURLs.append(url) })
        )
        let approval = dispatcher.approve(
            dispatcher.dispatch(
                AIAgentActionRequest.openFileURL(
                    id: "url",
                    url: URL(fileURLWithPath: "/tmp/report.txt")
                )
            ).approval
        )

        let result = dispatcher.dispatch(
            AIAgentActionRequest.openFileURL(
                id: "url",
                url: try XCTUnwrap(URL(string: "ssh://example.com/repo"))
            ),
            approval: approval
        )

        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.reason, "current action request is denied by policy")
        XCTAssertTrue(openedURLs.isEmpty)
    }

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
            requestedCapabilities: [
                AIAgentActionCapabilityRequest(
                    capability: "terminal.sendText",
                    reference: AICommandContextReference(
                        commandSpanID: 7,
                        targetPaneID: "pane-1",
                        targetWorkspaceID: "workspace-7"
                    ),
                    reason: "continue in selected pane"
                ),
            ],
            contextReferences: [
                AICommandContextReference(
                    commandSpanID: 7,
                    targetPaneID: "pane-1",
                    targetWorkspaceID: "workspace-7"
                ),
            ],
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
        XCTAssertEqual(audit.metadata.requestedCapabilities.first?.capability, "terminal.sendText")
        XCTAssertEqual(audit.metadata.requestedCapabilities.first?.reference?.commandSpanID, 7)
        XCTAssertEqual(audit.metadata.contextReferences.first?.targetPaneID, "pane-1")
        XCTAssertEqual(audit.metadata.persistenceScope, .session)
        XCTAssertEqual(audit.metadata.contextSummary, "selected command span")
        XCTAssertFalse(audit.redactedPreview.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(String(describing: audit).contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    func testCommandContextApprovalMetadataKeepsAgentTextExplicitlyApproved() {
        let metadata = AICommandContextBridge().approvalMetadata(
            for: .init(
                command: "swift test",
                cwd: "/Users/example/project",
                exitCode: 0
            ),
            actor: "planner-agent",
            targetPaneID: "pane-1",
            targetWorkspaceID: "workspace-7",
            capability: "send-text"
        )
        let evaluator = AIAgentActionApprovalEvaluator(maxPreviewLength: 80)
        let result = evaluator.evaluate(
            .sendText(
                id: "send-from-context",
                text: "make changes",
                metadata: metadata
            )
        )

        XCTAssertEqual(result.decision, .ask)
        XCTAssertEqual(result.reason, "agent terminal text requires explicit approval")
        XCTAssertEqual(result.metadata.actor, "planner-agent")
        XCTAssertEqual(result.metadata.targetPaneID, "pane-1")
        XCTAssertEqual(result.metadata.targetWorkspaceID, "workspace-7")
        XCTAssertEqual(result.metadata.cwd, "/Users/example/project")
        XCTAssertEqual(result.metadata.capability, "send-text")
        XCTAssertTrue(result.metadata.contextSummary?.contains("command: swift test") == true)

        let approved = evaluator.approve(result)
        XCTAssertEqual(approved.decision, .allow)
        XCTAssertEqual(approved.reason, "approved: agent terminal text requires explicit approval")
        XCTAssertEqual(approved.metadata, metadata)
    }

    func testCommandOutputExportApprovalCarriesReferenceAndRedactsRawPreview() throws {
        let rawToken = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let span = TerminalCommandSpan(
            id: 11,
            cwd: "/repo",
            startBoundarySequence: 30,
            endBoundarySequence: 34,
            exitCode: 0,
            promptBoundarySequence: 29,
            outputBoundarySequence: 32,
            commandText: "cat report"
        )
        let metadata = AICommandContextBridge().approvalMetadata(
            for: .init(span: span, output: "token=\(rawToken)"),
            targetPaneID: "pane-1",
            targetWorkspaceID: "workspace-7",
            capability: "command-output-export",
            includesRawOutput: true,
            rawOutputApproved: false,
            secretRedactionEnabled: true
        )
        let evaluator = AIAgentActionApprovalEvaluator(maxPreviewLength: 120)

        let result = evaluator.evaluate(
            .exportContext(
                id: "export-command-output",
                rawContext: "token=\(rawToken)",
                includesRawOutput: true,
                secretRedactionEnabled: true,
                metadata: metadata
            )
        )

        let commandOutput = try XCTUnwrap(result.metadata.commandOutput)
        XCTAssertEqual(result.decision, .ask)
        XCTAssertEqual(result.reason, "raw context export requires explicit approval")
        XCTAssertEqual(commandOutput.reference.commandSpanID, 11)
        XCTAssertEqual(commandOutput.reference.targetPaneID, "pane-1")
        XCTAssertEqual(commandOutput.reference.targetWorkspaceID, "workspace-7")
        XCTAssertTrue(commandOutput.includesRawOutput)
        XCTAssertFalse(commandOutput.rawOutputApproved)
        XCTAssertTrue(commandOutput.secretRedactionEnabled)
        XCTAssertTrue(commandOutput.explicitApprovalRequired)
        XCTAssertTrue(result.redactedPreview.contains("token=[REDACTED_SECRET]"))
        XCTAssertFalse(String(describing: result.auditRecord()).contains(rawToken))

        let approved = evaluator.approve(result)
        let approvedCommandOutput = try XCTUnwrap(approved.metadata.commandOutput)
        XCTAssertEqual(approved.decision, .allow)
        XCTAssertTrue(approvedCommandOutput.rawOutputApproved)
        XCTAssertFalse(approvedCommandOutput.explicitApprovalRequired)
        XCTAssertFalse(String(describing: approved.auditRecord()).contains(rawToken))
    }

    func testApprovingUnrelatedAskDoesNotApproveCommandOutputExportMetadata() throws {
        let metadata = AIAgentActionApprovalMetadata(
            capability: "send-text",
            commandOutput: AICommandOutputApprovalMetadata(
                reference: AICommandContextReference(commandSpanID: 42),
                includesRawOutput: true,
                rawOutputApproved: false,
                secretRedactionEnabled: true,
                explicitApprovalRequired: true
            )
        )
        let evaluator = AIAgentActionApprovalEvaluator(maxPreviewLength: 80)

        let result = evaluator.evaluate(
            .sendText(
                id: "send-with-command-output-reference",
                text: "echo ok",
                metadata: metadata
            )
        )
        let approved = evaluator.approve(result)

        let commandOutput = try XCTUnwrap(approved.metadata.commandOutput)
        XCTAssertEqual(result.decision, .ask)
        XCTAssertEqual(approved.decision, .allow)
        XCTAssertTrue(commandOutput.includesRawOutput)
        XCTAssertFalse(commandOutput.rawOutputApproved)
        XCTAssertTrue(commandOutput.explicitApprovalRequired)
    }

    func testAuditDescriptionRedactsSecretsInCapabilityAndContextMetadata() {
        let metadata = AIAgentActionApprovalMetadata(
            actor: "agent-token=actor-secret",
            targetPaneID: "pane-token=pane-secret",
            targetWorkspaceID: "workspace-api_key=workspace-secret",
            cwd: "/tmp/password=cwd-secret",
            capability: "terminal.sendText token=cap-secret",
            requestedCapabilities: [
                AIAgentActionCapabilityRequest(
                    capability: "terminal.pasteText token=request-secret",
                    reference: AICommandContextReference(
                        commandSpanID: 44,
                        targetPaneID: "pane-password=request-pane-secret",
                        targetWorkspaceID: "workspace-token=request-workspace-secret"
                    ),
                    reason: "needs token=reason-secret"
                ),
            ],
            contextReferences: [
                AICommandContextReference(
                    commandSpanID: 45,
                    targetPaneID: "pane-api_key=context-pane-secret",
                    targetWorkspaceID: "workspace-password=context-workspace-secret"
                ),
            ],
            contextSummary: "summary token=summary-secret"
        )
        let timestamp = Date(timeIntervalSince1970: 456)
        let audit = AIAgentActionAuditRecord(
            actionID: "send-secret",
            metadata: metadata,
            decision: .ask,
            reason: "agent terminal text requires explicit approval",
            redactedPreview: "echo ok",
            timestamp: timestamp
        )

        let description = String(describing: audit)

        XCTAssertFalse(description.contains("actor-secret"))
        XCTAssertFalse(description.contains("pane-secret"))
        XCTAssertFalse(description.contains("workspace-secret"))
        XCTAssertFalse(description.contains("cwd-secret"))
        XCTAssertFalse(description.contains("cap-secret"))
        XCTAssertFalse(description.contains("request-secret"))
        XCTAssertFalse(description.contains("request-pane-secret"))
        XCTAssertFalse(description.contains("request-workspace-secret"))
        XCTAssertFalse(description.contains("reason-secret"))
        XCTAssertFalse(description.contains("context-pane-secret"))
        XCTAssertFalse(description.contains("context-workspace-secret"))
        XCTAssertFalse(description.contains("summary-secret"))
        XCTAssertTrue(description.contains("targetPane=pane-token=[REDACTED_SECRET]"))
        XCTAssertTrue(description.contains("capability=terminal.sendText token=[REDACTED_SECRET]"))
    }

    func testApprovalDialogFlowModelCarriesVisibleContextAndGatesDispatch() {
        let metadata = AIAgentActionApprovalMetadata(
            actor: "planner-agent",
            targetPaneID: "pane-1",
            targetWorkspaceID: "workspace-7",
            cwd: "/repo",
            capability: "terminal.sendText",
            contextReferences: [
                AICommandContextReference(
                    commandSpanID: 42,
                    targetPaneID: "pane-1",
                    targetWorkspaceID: "workspace-7",
                    startBoundarySequence: 10,
                    outputBoundarySequence: 12,
                    endBoundarySequence: 14
                ),
            ],
            contextSummary: "command: deploy token=secret-token"
        )
        var sentText: [String] = []
        let dispatcher = AIAgentActionDispatcher(
            evaluator: AIAgentActionApprovalEvaluator(maxPreviewLength: 80),
            handlers: .init(sendText: { text, _ in sentText.append(text) })
        )
        let action = AIAgentActionRequest.sendText(
            id: "send-visible-context",
            text: "echo token=raw-secret",
            metadata: metadata
        )

        let pending = dispatcher.dispatch(action)
        let dialog = AIAgentActionApprovalDialogFlow(result: pending.approval)

        XCTAssertEqual(pending.status, .requiresApproval)
        XCTAssertEqual(dialog.title, "Approve AI Terminal Action")
        XCTAssertEqual(dialog.actionID, "send-visible-context")
        XCTAssertEqual(dialog.decision, .ask)
        XCTAssertEqual(dialog.contextReferences.map(\.commandSpanID), [42])
        XCTAssertEqual(dialog.summary, "command: deploy token=[REDACTED_SECRET]")
        XCTAssertTrue(dialog.redactedPreview.contains("token=[REDACTED_SECRET]"))
        XCTAssertFalse(String(describing: dialog).contains("raw-secret"))
        XCTAssertFalse(String(describing: dialog).contains("secret-token"))

        let denied = dispatcher.dispatch(action, dialogDecision: dialog.deny())
        XCTAssertEqual(denied.status, .denied)
        XCTAssertTrue(sentText.isEmpty)

        let approved = dispatcher.dispatch(action, dialogDecision: dialog.approve())
        XCTAssertEqual(approved.status, .dispatched)
        XCTAssertEqual(sentText, ["echo token=raw-secret"])
    }
}
