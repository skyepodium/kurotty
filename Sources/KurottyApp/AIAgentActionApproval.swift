import Foundation

enum AIAgentActionKind: String, Equatable, CustomStringConvertible {
    case sendText
    case pasteText
    case exportContext
    case openFileURL

    var description: String {
        rawValue
    }
}

enum AIAgentActionRequest: Equatable, CustomStringConvertible {
    case sendText(id: String, text: String, metadata: AIAgentActionApprovalMetadata = .init())
    case pasteText(
        id: String,
        text: String,
        origin: TerminalSecurityPolicy.Origin = .unknown,
        metadata: AIAgentActionApprovalMetadata = .init()
    )
    case exportContext(
        id: String,
        rawContext: String,
        includesRawOutput: Bool,
        secretRedactionEnabled: Bool = true,
        metadata: AIAgentActionApprovalMetadata = .init()
    )
    case openFileURL(id: String, url: URL, metadata: AIAgentActionApprovalMetadata = .init())

    var id: String {
        switch self {
        case let .sendText(id, _, _),
             let .pasteText(id, _, _, _),
             let .exportContext(id, _, _, _, _),
             let .openFileURL(id, _, _):
            return id
        }
    }

    var metadata: AIAgentActionApprovalMetadata {
        switch self {
        case let .sendText(_, _, metadata),
             let .pasteText(_, _, _, metadata),
             let .exportContext(_, _, _, _, metadata),
             let .openFileURL(_, _, metadata):
            return metadata
        }
    }

    var kind: AIAgentActionKind {
        switch self {
        case .sendText:
            return .sendText
        case .pasteText:
            return .pasteText
        case .exportContext:
            return .exportContext
        case .openFileURL:
            return .openFileURL
        }
    }

    var description: String {
        let preview = AIAgentActionApprovalSanitizer().preview(for: rawPreviewText)
        switch self {
        case let .sendText(id, _, metadata):
            return "sendText(id: \(id), metadata: \(metadata), preview: \(preview))"
        case let .pasteText(id, _, origin, metadata):
            return "pasteText(id: \(id), origin: \(origin), metadata: \(metadata), preview: \(preview))"
        case let .exportContext(id, _, includesRawOutput, secretRedactionEnabled, metadata):
            return "exportContext(id: \(id), includesRawOutput: \(includesRawOutput), secretRedactionEnabled: \(secretRedactionEnabled), metadata: \(metadata), preview: \(preview))"
        case let .openFileURL(id, url, metadata):
            return "openFileURL(id: \(id), url: \(url.absoluteString), metadata: \(metadata), preview: \(preview))"
        }
    }

    var approvalFingerprint: AIAgentActionApprovalFingerprint {
        switch self {
        case let .sendText(_, text, metadata):
            return AIAgentActionApprovalFingerprint(
                kind: .sendText,
                payload: .sendText(textLength: text.count, text: text),
                metadata: metadata
            )
        case let .pasteText(_, text, origin, metadata):
            return AIAgentActionApprovalFingerprint(
                kind: .pasteText,
                payload: .pasteText(textLength: text.count, origin: origin, text: text),
                metadata: metadata
            )
        case let .exportContext(_, rawContext, includesRawOutput, secretRedactionEnabled, metadata):
            return AIAgentActionApprovalFingerprint(
                kind: .exportContext,
                payload: .exportContext(
                    rawContextLength: rawContext.count,
                    rawContext: rawContext,
                    includesRawOutput: includesRawOutput,
                    secretRedactionEnabled: secretRedactionEnabled
                ),
                metadata: metadata
            )
        case let .openFileURL(_, url, metadata):
            return AIAgentActionApprovalFingerprint(
                kind: .openFileURL,
                payload: .openFileURL(absoluteString: url.absoluteString),
                metadata: metadata
            )
        }
    }

    fileprivate var rawPreviewText: String {
        switch self {
        case let .sendText(_, text, _),
             let .pasteText(_, text, _, _),
             let .exportContext(_, text, _, _, _):
            return text
        case let .openFileURL(_, url, _):
            return url.absoluteString
        }
    }
}

struct AIAgentActionApprovalFingerprint: Equatable, CustomStringConvertible {
    enum Payload: Equatable, CustomStringConvertible {
        case sendText(textLength: Int, text: String)
        case pasteText(textLength: Int, origin: TerminalSecurityPolicy.Origin, text: String)
        case exportContext(
            rawContextLength: Int,
            rawContext: String,
            includesRawOutput: Bool,
            secretRedactionEnabled: Bool
        )
        case openFileURL(absoluteString: String)

        var description: String {
            switch self {
            case let .sendText(textLength, _):
                return "sendText(textLength: \(textLength))"
            case let .pasteText(textLength, origin, _):
                return "pasteText(textLength: \(textLength), origin: \(origin))"
            case let .exportContext(rawContextLength, _, includesRawOutput, secretRedactionEnabled):
                return "exportContext(rawContextLength: \(rawContextLength), includesRawOutput: \(includesRawOutput), secretRedactionEnabled: \(secretRedactionEnabled))"
            case let .openFileURL(absoluteString):
                return "openFileURL(urlLength: \(absoluteString.count))"
            }
        }
    }

    let kind: AIAgentActionKind
    let payload: Payload
    let metadata: AIAgentActionApprovalMetadata

    var description: String {
        "AIAgentActionApprovalFingerprint(kind: \(kind), payload: \(payload), metadata: \(metadata))"
    }
}

struct AIAgentActionApprovalMetadata: Equatable, CustomStringConvertible {
    enum PersistenceScope: String, Equatable, CustomStringConvertible {
        case oneTime
        case session
        case profile

        var description: String {
            rawValue
        }
    }

    var actor: String
    var targetPaneID: String?
    var targetWorkspaceID: String?
    var cwd: String?
    var capability: String
    var requestedCapabilities: [AIAgentActionCapabilityRequest]
    var contextReferences: [AICommandContextReference]
    var persistenceScope: PersistenceScope
    var contextSummary: String?
    var commandOutput: AICommandOutputApprovalMetadata?

    init(
        actor: String = "ai-agent",
        targetPaneID: String? = nil,
        targetWorkspaceID: String? = nil,
        cwd: String? = nil,
        capability: String = "terminal-action",
        requestedCapabilities: [AIAgentActionCapabilityRequest] = [],
        contextReferences: [AICommandContextReference] = [],
        persistenceScope: PersistenceScope = .oneTime,
        contextSummary: String? = nil,
        commandOutput: AICommandOutputApprovalMetadata? = nil
    ) {
        self.actor = actor
        self.targetPaneID = targetPaneID
        self.targetWorkspaceID = targetWorkspaceID
        self.cwd = cwd
        self.capability = capability
        self.requestedCapabilities = requestedCapabilities
        self.contextReferences = contextReferences
        self.persistenceScope = persistenceScope
        self.contextSummary = contextSummary
        self.commandOutput = commandOutput
    }

    var description: String {
        [
            "actor=\(actor)",
            "targetPane=\(targetPaneID ?? "unknown")",
            "targetWorkspace=\(targetWorkspaceID ?? "unknown")",
            "cwd=\(cwd ?? "unknown")",
            "capability=\(capability)",
            "requestedCapabilities=\(requestedCapabilities.isEmpty ? "unspecified" : requestedCapabilities.map(\.description).joined(separator: ","))",
            "contextReferences=\(contextReferences.isEmpty ? "unspecified" : contextReferences.map(\.description).joined(separator: ","))",
            "persistence=\(persistenceScope)",
            "context=\(contextSummary ?? "unspecified")",
            "commandOutput=\(commandOutput?.description ?? "unspecified")",
        ].map(aiApprovalRedacted).joined(separator: " ")
    }

    func markingCommandOutputApproved() -> Self {
        guard let commandOutput, commandOutput.includesRawOutput else {
            return self
        }

        var metadata = self
        metadata.commandOutput = commandOutput.markingApproved()
        return metadata
    }
}

struct AIAgentActionCapabilityRequest: Equatable, CustomStringConvertible {
    let capability: String
    let reference: AICommandContextReference?
    let reason: String?

    init(
        capability: String,
        reference: AICommandContextReference? = nil,
        reason: String? = nil
    ) {
        self.capability = capability
        self.reference = reference
        self.reason = reason
    }

    var description: String {
        [
            "capability=\(capability)",
            "reference=[\(reference?.description ?? "unspecified")]",
            "reason=\(reason ?? "unspecified")",
        ].map(aiApprovalRedacted).joined(separator: " ")
    }
}

struct AICommandContextReference: Equatable, CustomStringConvertible {
    let commandSpanID: Int?
    let targetPaneID: String?
    let targetWorkspaceID: String?
    let promptBoundarySequence: Int?
    let startBoundarySequence: Int?
    let outputBoundarySequence: Int?
    let endBoundarySequence: Int?

    init(
        commandSpanID: Int? = nil,
        targetPaneID: String? = nil,
        targetWorkspaceID: String? = nil,
        promptBoundarySequence: Int? = nil,
        startBoundarySequence: Int? = nil,
        outputBoundarySequence: Int? = nil,
        endBoundarySequence: Int? = nil
    ) {
        self.commandSpanID = commandSpanID
        self.targetPaneID = targetPaneID
        self.targetWorkspaceID = targetWorkspaceID
        self.promptBoundarySequence = promptBoundarySequence
        self.startBoundarySequence = startBoundarySequence
        self.outputBoundarySequence = outputBoundarySequence
        self.endBoundarySequence = endBoundarySequence
    }

    init(span: TerminalCommandSpan) {
        self.init(
            commandSpanID: span.id,
            promptBoundarySequence: span.promptBoundarySequence,
            startBoundarySequence: span.startBoundarySequence,
            outputBoundarySequence: span.outputBoundarySequence,
            endBoundarySequence: span.endBoundarySequence
        )
    }

    func retargeted(targetPaneID: String?, targetWorkspaceID: String?) -> Self {
        Self(
            commandSpanID: commandSpanID,
            targetPaneID: targetPaneID,
            targetWorkspaceID: targetWorkspaceID,
            promptBoundarySequence: promptBoundarySequence,
            startBoundarySequence: startBoundarySequence,
            outputBoundarySequence: outputBoundarySequence,
            endBoundarySequence: endBoundarySequence
        )
    }

    var description: String {
        [
            "commandSpanID=\(commandSpanID.map(String.init) ?? "unknown")",
            "targetPane=\(targetPaneID ?? "unknown")",
            "targetWorkspace=\(targetWorkspaceID ?? "unknown")",
            "promptBoundary=\(promptBoundarySequence.map(String.init) ?? "unknown")",
            "startBoundary=\(startBoundarySequence.map(String.init) ?? "unknown")",
            "outputBoundary=\(outputBoundarySequence.map(String.init) ?? "unknown")",
            "endBoundary=\(endBoundarySequence.map(String.init) ?? "unknown")",
        ].map(aiApprovalRedacted).joined(separator: " ")
    }
}

struct AICommandOutputApprovalMetadata: Equatable, CustomStringConvertible {
    let reference: AICommandContextReference
    let includesRawOutput: Bool
    let rawOutputApproved: Bool
    let secretRedactionEnabled: Bool
    let explicitApprovalRequired: Bool

    init(
        reference: AICommandContextReference,
        includesRawOutput: Bool,
        rawOutputApproved: Bool,
        secretRedactionEnabled: Bool,
        explicitApprovalRequired: Bool
    ) {
        self.reference = reference
        self.includesRawOutput = includesRawOutput
        self.rawOutputApproved = rawOutputApproved
        self.secretRedactionEnabled = secretRedactionEnabled
        self.explicitApprovalRequired = explicitApprovalRequired
    }

    var description: String {
        [
            "reference=[\(reference)]",
            "includesRawOutput=\(includesRawOutput)",
            "rawOutputApproved=\(rawOutputApproved)",
            "secretRedactionEnabled=\(secretRedactionEnabled)",
            "explicitApprovalRequired=\(explicitApprovalRequired)",
        ].joined(separator: " ")
    }

    func markingApproved() -> Self {
        Self(
            reference: reference,
            includesRawOutput: includesRawOutput,
            rawOutputApproved: true,
            secretRedactionEnabled: secretRedactionEnabled,
            explicitApprovalRequired: false
        )
    }
}

private func aiApprovalRedacted(_ text: String) -> String {
    AIContextRedactor().redacted(text)
}

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

private struct AIAgentActionApprovalSanitizer {
    private static let redactionLookaheadCharacters = 256

    private let maxPreviewLength: Int
    private let redactor: AIContextRedactor

    init(maxPreviewLength: Int = 160, redactor: AIContextRedactor = AIContextRedactor()) {
        self.maxPreviewLength = max(0, maxPreviewLength)
        self.redactor = redactor
    }

    func preview(for text: String) -> String {
        let boundedText = String(text.prefix(maxPreviewLength + Self.redactionLookaheadCharacters))
        return String(redactor.redacted(boundedText).prefix(maxPreviewLength))
    }
}
