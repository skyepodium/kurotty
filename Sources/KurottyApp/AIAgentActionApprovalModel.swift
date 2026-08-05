import Foundation

/// Value types for the AI agent action approval pipeline: the action request,
/// its approval fingerprint, and the metadata attached to every decision.
/// Extracted verbatim from `AIAgentActionApproval.swift`, which keeps the
/// evaluator, dispatcher, and dialog flow.

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

    var rawPreviewText: String {
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

func aiApprovalRedacted(_ text: String) -> String {
    AIContextRedactor().redacted(text)
}

struct AIAgentActionApprovalSanitizer {
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
