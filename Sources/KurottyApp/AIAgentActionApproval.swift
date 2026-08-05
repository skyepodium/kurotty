import Foundation

// Request, fingerprint, and metadata types live in
// AIAgentActionApprovalModel.swift.

struct AIAgentActionApprovalResult: Equatable {
    let actionID: String
    let actionKind: AIAgentActionKind
    let actionFingerprint: AIAgentActionApprovalFingerprint
    let metadata: AIAgentActionApprovalMetadata
    let decision: TerminalSecurityPolicy.Decision
    let reason: String
    let redactedPreview: String
    let timestamp: Date
    let approvesCommandOutputExport: Bool

    func auditRecord() -> AIAgentActionAuditRecord {
        AIAgentActionAuditRecord(
            actionID: actionID,
            metadata: metadata,
            decision: decision,
            reason: reason,
            redactedPreview: redactedPreview,
            timestamp: timestamp
        )
    }
}

struct AIAgentActionAuditRecord: Equatable, CustomStringConvertible {
    let actionID: String
    let metadata: AIAgentActionApprovalMetadata
    let decision: TerminalSecurityPolicy.Decision
    let reason: String
    let redactedPreview: String
    let timestamp: Date

    var description: String {
        "AIAgentActionAuditRecord(actionID: \(actionID), metadata: \(metadata), decision: \(decision), reason: \(reason), redactedPreview: \(redactedPreview), timestamp: \(timestamp.formatted(.iso8601)))"
    }
}

struct AIAgentActionDispatchHandlers {
    var sendText: (String, AIAgentActionApprovalMetadata) -> Void
    var pasteText: (String, TerminalSecurityPolicy.Origin, AIAgentActionApprovalMetadata) -> Void
    var exportContext: (String, AIAgentActionApprovalMetadata) -> Void
    var openFileURL: (URL, AIAgentActionApprovalMetadata) -> Void

    init(
        sendText: @escaping (String, AIAgentActionApprovalMetadata) -> Void = { _, _ in },
        pasteText: @escaping (String, TerminalSecurityPolicy.Origin, AIAgentActionApprovalMetadata) -> Void = { _, _, _ in },
        exportContext: @escaping (String, AIAgentActionApprovalMetadata) -> Void = { _, _ in },
        openFileURL: @escaping (URL, AIAgentActionApprovalMetadata) -> Void = { _, _ in }
    ) {
        self.sendText = sendText
        self.pasteText = pasteText
        self.exportContext = exportContext
        self.openFileURL = openFileURL
    }
}

struct AIAgentActionDispatchResult: Equatable {
    enum Status: String, Equatable, CustomStringConvertible {
        case dispatched
        case requiresApproval
        case denied

        var description: String {
            rawValue
        }
    }

    let actionID: String
    let kind: AIAgentActionKind
    let status: Status
    let approval: AIAgentActionApprovalResult

    var audit: AIAgentActionAuditRecord {
        approval.auditRecord()
    }

    var reason: String {
        approval.reason
    }
}

struct AIAgentActionApprovalDialogFlow: Equatable, CustomStringConvertible {
    struct Decision: Equatable {
        let approval: AIAgentActionApprovalResult
    }

    struct PresentationRow: Equatable, CustomStringConvertible {
        let label: String
        let value: String
        let requiresExplicitApproval: Bool

        init(
            label: String,
            value: String,
            requiresExplicitApproval: Bool = false
        ) {
            self.label = label
            self.value = value
            self.requiresExplicitApproval = requiresExplicitApproval
        }

        var description: String {
            "PresentationRow(label: \(label), value: \(value), requiresExplicitApproval: \(requiresExplicitApproval))"
        }
    }

    let actionID: String
    let kind: AIAgentActionKind
    let title: String
    let decision: TerminalSecurityPolicy.Decision
    let reason: String
    let redactedPreview: String
    let summary: String?
    let contextReferences: [AICommandContextReference]
    let metadata: AIAgentActionApprovalMetadata
    private let actionFingerprint: AIAgentActionApprovalFingerprint

    init(result: AIAgentActionApprovalResult) {
        self.actionID = result.actionID
        self.kind = result.actionKind
        self.title = Self.title(for: result)
        self.decision = result.decision
        self.reason = result.reason
        self.redactedPreview = result.redactedPreview
        self.summary = result.metadata.contextSummary.map(aiApprovalRedacted)
        self.contextReferences = result.metadata.contextReferences
        self.metadata = result.metadata
        self.actionFingerprint = result.actionFingerprint
    }

    var description: String {
        [
            "AIAgentActionApprovalDialogFlow(actionID: \(actionID)",
            "kind: \(kind)",
            "decision: \(decision)",
            "reason: \(reason)",
            "preview: \(redactedPreview)",
            "summary: \(summary ?? "unspecified"))",
        ].map(aiApprovalRedacted).joined(separator: " ")
    }

    var presentationRows: [PresentationRow] {
        var rows: [PresentationRow] = [
            PresentationRow(label: "Actor", value: aiApprovalRedacted(metadata.actor)),
            PresentationRow(label: "Capability", value: aiApprovalRedacted(metadata.capability)),
        ]

        if let target = targetValue() {
            rows.append(PresentationRow(label: "Target", value: target))
        }
        if let cwd = metadata.cwd {
            rows.append(PresentationRow(label: "Working Directory", value: aiApprovalRedacted(cwd)))
        }
        rows.append(PresentationRow(label: "Persistence", value: metadata.persistenceScope.description))

        rows.append(contentsOf: contextReferences.compactMap { reference in
            contextReferenceRow(for: reference)
        })

        if let commandOutput = metadata.commandOutput {
            rows.append(commandOutputRow(for: commandOutput))
        }

        return rows
    }

    func approve() -> Decision {
        Decision(approval: approvalResult(decision: .allow, reasonPrefix: "approved"))
    }

    func deny() -> Decision {
        Decision(approval: approvalResult(decision: .deny, reasonPrefix: "denied"))
    }

    private func approvalResult(
        decision: TerminalSecurityPolicy.Decision,
        reasonPrefix: String
    ) -> AIAgentActionApprovalResult {
        AIAgentActionApprovalResult(
            actionID: actionID,
            actionKind: kind,
            actionFingerprint: actionFingerprint,
            metadata: decision == .allow ? metadata.markingCommandOutputApproved() : metadata,
            decision: decision,
            reason: "\(reasonPrefix): \(reason)",
            redactedPreview: redactedPreview,
            timestamp: Date(),
            approvesCommandOutputExport: metadata.commandOutput?.includesRawOutput == true
        )
    }

    private static func title(for result: AIAgentActionApprovalResult) -> String {
        switch result.decision {
        case .allow:
            return "AI Terminal Action Allowed"
        case .ask:
            return "Approve AI Terminal Action"
        case .deny:
            return "AI Terminal Action Denied"
        }
    }

    private func targetValue() -> String? {
        switch (metadata.targetPaneID, metadata.targetWorkspaceID) {
        case let (.some(paneID), .some(workspaceID)):
            return "\(aiApprovalRedacted(paneID)) / \(aiApprovalRedacted(workspaceID))"
        case let (.some(paneID), .none):
            return aiApprovalRedacted(paneID)
        case let (.none, .some(workspaceID)):
            return aiApprovalRedacted(workspaceID)
        case (.none, .none):
            return nil
        }
    }

    private func contextReferenceRow(for reference: AICommandContextReference) -> PresentationRow? {
        let hasReference = reference.commandSpanID != nil
            || reference.startBoundarySequence != nil
            || reference.endBoundarySequence != nil
            || reference.targetPaneID != nil
            || reference.targetWorkspaceID != nil
        guard hasReference else {
            return nil
        }

        var value = reference.commandSpanID.map { "Command #\($0)" } ?? "Command reference"
        if let start = reference.startBoundarySequence,
           let end = reference.endBoundarySequence {
            value += " boundaries \(start)-\(end)"
        } else if let output = reference.outputBoundarySequence {
            value += " output boundary \(output)"
        }
        return PresentationRow(label: "Context Reference", value: aiApprovalRedacted(value))
    }

    private func commandOutputRow(for commandOutput: AICommandOutputApprovalMetadata) -> PresentationRow {
        let outputState: String
        if commandOutput.includesRawOutput {
            outputState = commandOutput.rawOutputApproved ? "Raw output approved" : "Raw output requires approval"
        } else {
            outputState = "Raw output omitted"
        }

        let redactionState = commandOutput.secretRedactionEnabled
            ? "redaction enabled"
            : "redaction disabled"
        return PresentationRow(
            label: "Command Output",
            value: "\(outputState); \(redactionState)",
            requiresExplicitApproval: commandOutput.explicitApprovalRequired
        )
    }
}

struct AIAgentActionDispatcher {
    private let evaluator: AIAgentActionApprovalEvaluator
    private let handlers: AIAgentActionDispatchHandlers

    init(
        evaluator: AIAgentActionApprovalEvaluator = AIAgentActionApprovalEvaluator(),
        handlers: AIAgentActionDispatchHandlers = AIAgentActionDispatchHandlers()
    ) {
        self.evaluator = evaluator
        self.handlers = handlers
    }

    func approve(_ approval: AIAgentActionApprovalResult) -> AIAgentActionApprovalResult {
        evaluator.approve(approval)
    }

    func dispatch(
        _ action: AIAgentActionRequest,
        approval suppliedApproval: AIAgentActionApprovalResult? = nil
    ) -> AIAgentActionDispatchResult {
        let evaluated = evaluator.evaluate(action)

        if let suppliedApproval {
            return dispatchApproved(action, evaluated: evaluated, approval: suppliedApproval)
        }

        switch evaluated.decision {
        case .allow:
            invokeHandler(for: action, metadata: evaluated.metadata)
            return result(for: action, status: .dispatched, approval: evaluated)
        case .ask:
            return result(for: action, status: .requiresApproval, approval: evaluated)
        case .deny:
            return result(for: action, status: .denied, approval: evaluated)
        }
    }

    func dispatch(
        _ action: AIAgentActionRequest,
        dialogDecision: AIAgentActionApprovalDialogFlow.Decision
    ) -> AIAgentActionDispatchResult {
        let evaluated = evaluator.evaluate(action)
        let suppliedApproval = AIAgentActionApprovalResult(
            actionID: dialogDecision.approval.actionID,
            actionKind: dialogDecision.approval.actionKind,
            actionFingerprint: dialogDecision.approval.actionFingerprint,
            metadata: dialogDecision.approval.decision == .allow
                ? evaluated.metadata.markingCommandOutputApproved()
                : evaluated.metadata,
            decision: dialogDecision.approval.decision,
            reason: dialogDecision.approval.reason,
            redactedPreview: dialogDecision.approval.redactedPreview,
            timestamp: dialogDecision.approval.timestamp,
            approvesCommandOutputExport: dialogDecision.approval.approvesCommandOutputExport
        )
        guard suppliedApproval.decision != .deny else {
            return result(for: action, status: .denied, approval: suppliedApproval)
        }
        return dispatchApproved(action, evaluated: evaluated, approval: suppliedApproval)
    }

    private func dispatchApproved(
        _ action: AIAgentActionRequest,
        evaluated: AIAgentActionApprovalResult,
        approval: AIAgentActionApprovalResult
    ) -> AIAgentActionDispatchResult {
        guard evaluated.decision != .deny else {
            return result(
                for: action,
                status: .denied,
                approval: denial(
                    for: evaluated,
                    reason: "current action request is denied by policy"
                )
            )
        }
        guard approval.actionID == action.id else {
            return result(
                for: action,
                status: .denied,
                approval: denial(
                    for: evaluated,
                    reason: "approval result does not match action request"
                )
            )
        }
        guard approval.actionKind == action.kind else {
            return result(
                for: action,
                status: .denied,
                approval: denial(
                    for: evaluated,
                    reason: "approval result kind does not match action request"
                )
            )
        }
        guard approval.actionFingerprint == action.approvalFingerprint else {
            return result(
                for: action,
                status: .denied,
                approval: denial(
                    for: evaluated,
                    reason: "approval result fingerprint does not match action request"
                )
            )
        }
        guard approval.decision == .allow else {
            return result(
                for: action,
                status: .requiresApproval,
                approval: evaluated
            )
        }

        invokeHandler(for: action, metadata: approval.metadata)
        return result(for: action, status: .dispatched, approval: approval)
    }

    private func invokeHandler(
        for action: AIAgentActionRequest,
        metadata: AIAgentActionApprovalMetadata
    ) {
        switch action {
        case let .sendText(_, text, _):
            handlers.sendText(text, metadata)
        case let .pasteText(_, text, origin, _):
            handlers.pasteText(text, origin, metadata)
        case let .exportContext(_, rawContext, _, _, _):
            handlers.exportContext(rawContext, metadata)
        case let .openFileURL(_, url, _):
            handlers.openFileURL(url, metadata)
        }
    }

    private func result(
        for action: AIAgentActionRequest,
        status: AIAgentActionDispatchResult.Status,
        approval: AIAgentActionApprovalResult
    ) -> AIAgentActionDispatchResult {
        AIAgentActionDispatchResult(
            actionID: action.id,
            kind: action.kind,
            status: status,
            approval: approval
        )
    }

    private func denial(
        for approval: AIAgentActionApprovalResult,
        reason: String
    ) -> AIAgentActionApprovalResult {
        AIAgentActionApprovalResult(
            actionID: approval.actionID,
            actionKind: approval.actionKind,
            actionFingerprint: approval.actionFingerprint,
            metadata: approval.metadata,
            decision: .deny,
            reason: reason,
            redactedPreview: approval.redactedPreview,
            timestamp: approval.timestamp,
            approvesCommandOutputExport: false
        )
    }
}

struct AIAgentActionApprovalEvaluator {
    private let securityPolicy: TerminalSecurityPolicy
    private let sanitizer: AIAgentActionApprovalSanitizer
    private let now: () -> Date

    init(
        securityPolicy: TerminalSecurityPolicy = .default,
        maxPreviewLength: Int = 160,
        now: @escaping () -> Date = Date.init
    ) {
        self.securityPolicy = securityPolicy
        self.sanitizer = AIAgentActionApprovalSanitizer(maxPreviewLength: maxPreviewLength)
        self.now = now
    }

    func evaluate(_ action: AIAgentActionRequest) -> AIAgentActionApprovalResult {
        let decisionAndReason = decisionAndReason(for: action)
        return AIAgentActionApprovalResult(
            actionID: action.id,
            actionKind: action.kind,
            actionFingerprint: action.approvalFingerprint,
            metadata: action.metadata,
            decision: decisionAndReason.decision,
            reason: decisionAndReason.reason,
            redactedPreview: sanitizer.preview(for: action.rawPreviewText),
            timestamp: now(),
            approvesCommandOutputExport: approvesCommandOutputExport(for: action, decision: decisionAndReason.decision)
        )
    }

    func approve(_ result: AIAgentActionApprovalResult) -> AIAgentActionApprovalResult {
        guard result.decision == .ask else {
            return result
        }

        return AIAgentActionApprovalResult(
            actionID: result.actionID,
            actionKind: result.actionKind,
            actionFingerprint: result.actionFingerprint,
            metadata: result.approvesCommandOutputExport
                ? result.metadata.markingCommandOutputApproved()
                : result.metadata,
            decision: .allow,
            reason: "approved: \(result.reason)",
            redactedPreview: result.redactedPreview,
            timestamp: now(),
            approvesCommandOutputExport: result.approvesCommandOutputExport
        )
    }

    private func approvesCommandOutputExport(
        for action: AIAgentActionRequest,
        decision: TerminalSecurityPolicy.Decision
    ) -> Bool {
        guard decision == .ask,
              case let .exportContext(_, _, includesRawOutput, _, metadata) = action
        else {
            return false
        }

        return includesRawOutput && (metadata.commandOutput?.includesRawOutput == true)
    }

    private func decisionAndReason(
        for action: AIAgentActionRequest
    ) -> (decision: TerminalSecurityPolicy.Decision, reason: String) {
        switch action {
        case .sendText:
            return (.ask, "agent terminal text requires explicit approval")
        case let .pasteText(_, _, origin, _):
            return reason(
                for: securityPolicy.decision(for: .clipboardWrite, origin: origin),
                allow: "clipboard paste allowed by policy",
                ask: "clipboard paste requires explicit approval",
                deny: "clipboard paste denied by terminal security policy"
            )
        case let .exportContext(_, _, includesRawOutput, secretRedactionEnabled, _):
            let request = TerminalSecurityPolicy.AIContextRequest(
                rawOutputRequested: includesRawOutput,
                secretRedactionEnabled: secretRedactionEnabled
            )
            return reason(
                for: securityPolicy.aiContextExportDecision(request),
                allow: "redacted context export allowed by policy",
                ask: "raw context export requires explicit approval",
                deny: secretRedactionEnabled
                    ? "context export denied by terminal security policy"
                    : "raw context export requires secret redaction"
            )
        case let .openFileURL(_, url, _):
            return reason(
                for: securityPolicy.linkOpenDecision(for: url),
                allow: "URL open allowed by policy",
                ask: "URL open requires explicit approval",
                deny: "URL open denied by terminal security policy"
            )
        }
    }

    private func reason(
        for decision: TerminalSecurityPolicy.Decision,
        allow: String,
        ask: String,
        deny: String
    ) -> (decision: TerminalSecurityPolicy.Decision, reason: String) {
        switch decision {
        case .allow:
            return (.allow, allow)
        case .ask:
            return (.ask, ask)
        case .deny:
            return (.deny, deny)
        }
    }
}
