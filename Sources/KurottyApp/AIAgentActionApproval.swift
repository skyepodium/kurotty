import Foundation

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
    var persistenceScope: PersistenceScope
    var contextSummary: String?

    init(
        actor: String = "ai-agent",
        targetPaneID: String? = nil,
        targetWorkspaceID: String? = nil,
        cwd: String? = nil,
        capability: String = "terminal-action",
        persistenceScope: PersistenceScope = .oneTime,
        contextSummary: String? = nil
    ) {
        self.actor = actor
        self.targetPaneID = targetPaneID
        self.targetWorkspaceID = targetWorkspaceID
        self.cwd = cwd
        self.capability = capability
        self.persistenceScope = persistenceScope
        self.contextSummary = contextSummary
    }

    var description: String {
        [
            "actor=\(actor)",
            "targetPane=\(targetPaneID ?? "unknown")",
            "targetWorkspace=\(targetWorkspaceID ?? "unknown")",
            "cwd=\(cwd ?? "unknown")",
            "capability=\(capability)",
            "persistence=\(persistenceScope)",
            "context=\(contextSummary ?? "unspecified")",
        ].joined(separator: " ")
    }
}

struct AIAgentActionApprovalResult: Equatable {
    let actionID: String
    let metadata: AIAgentActionApprovalMetadata
    let decision: TerminalSecurityPolicy.Decision
    let reason: String
    let redactedPreview: String
    let timestamp: Date

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
            metadata: action.metadata,
            decision: decisionAndReason.decision,
            reason: decisionAndReason.reason,
            redactedPreview: sanitizer.preview(for: action.rawPreviewText),
            timestamp: now()
        )
    }

    func approve(_ result: AIAgentActionApprovalResult) -> AIAgentActionApprovalResult {
        guard result.decision == .ask else {
            return result
        }

        return AIAgentActionApprovalResult(
            actionID: result.actionID,
            metadata: result.metadata,
            decision: .allow,
            reason: "approved: \(result.reason)",
            redactedPreview: result.redactedPreview,
            timestamp: now()
        )
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
