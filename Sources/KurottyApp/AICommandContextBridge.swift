import Foundation

struct AICommandContextBridge {
    struct CommandContext: Equatable {
        let command: String
        let output: String?
        let cwd: String?
        let exitCode: Int?
        let startedAt: Date?
        let endedAt: Date?
        let reference: AICommandContextReference?

        init(
            command: String,
            output: String? = nil,
            cwd: String? = nil,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            reference: AICommandContextReference? = nil
        ) {
            self.command = command
            self.output = output
            self.cwd = cwd
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.reference = reference
        }

        init(
            span: TerminalCommandSpan,
            output: String? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil
        ) {
            self.init(
                command: span.commandText ?? "",
                output: output,
                cwd: span.cwd,
                exitCode: span.exitCode,
                startedAt: startedAt,
                endedAt: endedAt,
                reference: AICommandContextReference(span: span)
            )
        }
    }

    struct Options: Equatable {
        let includeRawOutput: Bool
        let rawOutputApproved: Bool
        let auditSource: String
        let auditNote: String

        init(
            includeRawOutput: Bool = false,
            rawOutputApproved: Bool = false,
            auditSource: String = "ai-command-context-bridge",
            auditNote: String = "redacted command context"
        ) {
            self.includeRawOutput = includeRawOutput
            self.rawOutputApproved = rawOutputApproved
            self.auditSource = auditSource
            self.auditNote = auditNote
        }
    }

    let securityPolicy: TerminalSecurityPolicy

    init(securityPolicy: TerminalSecurityPolicy = .default) {
        self.securityPolicy = securityPolicy
    }

    @discardableResult
    func appendSnapshot(
        for context: CommandContext,
        to eventLog: inout AIContextEventLog,
        options: Options = Options()
    ) -> AIContextSnapshot {
        eventLog.record(
            source: "terminal-command",
            text: metadataText(for: context, includesOutput: shouldIncludeOutput(context, options: options))
        )

        let output = outputText(for: context, options: options)
        if !output.isEmpty {
            eventLog.record(source: "terminal-output", text: output)
        }

        return eventLog.snapshot(
            command: context.command,
            output: output,
            cwd: context.cwd ?? "",
            exitCode: context.exitCode,
            auditSource: options.auditSource,
            auditNote: auditNote(for: options)
        )
    }

    func snapshot(
        for context: CommandContext,
        maxEvents: Int = 16,
        maxTextLength: Int = 4_096,
        options: Options = Options()
    ) -> AIContextSnapshot {
        var eventLog = AIContextEventLog(maxEvents: maxEvents, maxTextLength: maxTextLength)
        return appendSnapshot(for: context, to: &eventLog, options: options)
    }

    func approvalMetadata(
        for context: CommandContext,
        actor: String = "ai-agent",
        targetPaneID: String? = nil,
        targetWorkspaceID: String? = nil,
        capability: String = "terminal-action",
        requestedCapabilities: [AIAgentActionCapabilityRequest]? = nil,
        contextReferences: [AICommandContextReference] = [],
        persistenceScope: AIAgentActionApprovalMetadata.PersistenceScope = .oneTime,
        maxContextSummaryLength: Int = 320,
        includesRawOutput: Bool = false,
        rawOutputApproved: Bool = false,
        secretRedactionEnabled: Bool = true
    ) -> AIAgentActionApprovalMetadata {
        let sanitizedPaneID = targetPaneID.map { sanitized($0) }
        let sanitizedWorkspaceID = targetWorkspaceID.map { sanitized($0) }
        let reference = sanitizedReference(
            context.reference,
            targetPaneID: sanitizedPaneID,
            targetWorkspaceID: sanitizedWorkspaceID
        )
        let sanitizedCapability = sanitized(capability)
        let sanitizedContextReferences = (contextReferences + defaultContextReferences(from: reference))
            .map { sanitizedReference($0, targetPaneID: nil, targetWorkspaceID: nil) }
        let sanitizedCapabilityRequests = requestedCapabilities.map { requests in
            requests.map(sanitizedCapabilityRequest)
        } ?? [
            AIAgentActionCapabilityRequest(
                capability: sanitizedCapability,
                reference: reference,
                reason: "explicit approval capability request"
            ),
        ]
        return AIAgentActionApprovalMetadata(
            actor: sanitized(actor),
            targetPaneID: sanitizedPaneID,
            targetWorkspaceID: sanitizedWorkspaceID,
            cwd: context.cwd.map { sanitized($0) },
            capability: sanitizedCapability,
            requestedCapabilities: sanitizedCapabilityRequests,
            contextReferences: sanitizedContextReferences,
            persistenceScope: persistenceScope,
            contextSummary: sanitized(
                metadataText(for: context, includesOutput: false),
                maxTextLength: maxContextSummaryLength
            ),
            commandOutput: AICommandOutputApprovalMetadata(
                reference: reference,
                includesRawOutput: includesRawOutput,
                rawOutputApproved: rawOutputApproved,
                secretRedactionEnabled: secretRedactionEnabled,
                explicitApprovalRequired: includesRawOutput && !rawOutputApproved
            )
        )
    }

    private func outputText(for context: CommandContext, options: Options) -> String {
        guard shouldIncludeOutput(context, options: options), let output = context.output else {
            return ""
        }
        return output
    }

    private func shouldIncludeOutput(_ context: CommandContext, options: Options) -> Bool {
        guard options.includeRawOutput, context.output != nil else {
            return false
        }

        let decision = securityPolicy.aiContextExportDecision(
            .init(rawOutputRequested: true, secretRedactionEnabled: true)
        )
        return decision == .allow || (decision == .ask && options.rawOutputApproved)
    }

    private func metadataText(for context: CommandContext, includesOutput: Bool) -> String {
        var lines = [
            "command: \(context.command)",
            "cwd: \(context.cwd ?? "")",
            "exitCode: \(context.exitCode.map(String.init) ?? "nil")",
            "rawOutput: \(includesOutput ? "included" : "omitted")",
        ]

        if let startedAt = context.startedAt {
            lines.append("startedAt: \(startedAt.formatted(.iso8601))")
        }
        if let endedAt = context.endedAt {
            lines.append("endedAt: \(endedAt.formatted(.iso8601))")
        }
        appendReferenceLines(context.reference, to: &lines)

        return lines.joined(separator: "\n")
    }

    private func appendReferenceLines(
        _ reference: AICommandContextReference?,
        to lines: inout [String]
    ) {
        guard let reference else {
            return
        }

        if let commandSpanID = reference.commandSpanID {
            lines.append("commandSpanID: \(commandSpanID)")
        }
        if let targetPaneID = reference.targetPaneID {
            lines.append("targetPaneID: \(targetPaneID)")
        }
        if let targetWorkspaceID = reference.targetWorkspaceID {
            lines.append("targetWorkspaceID: \(targetWorkspaceID)")
        }
        if let promptBoundarySequence = reference.promptBoundarySequence {
            lines.append("promptBoundarySequence: \(promptBoundarySequence)")
        }
        if let startBoundarySequence = reference.startBoundarySequence {
            lines.append("startBoundarySequence: \(startBoundarySequence)")
        }
        if let outputBoundarySequence = reference.outputBoundarySequence {
            lines.append("outputBoundarySequence: \(outputBoundarySequence)")
        }
        if let endBoundarySequence = reference.endBoundarySequence {
            lines.append("endBoundarySequence: \(endBoundarySequence)")
        }
    }

    private func sanitizedReference(
        _ reference: AICommandContextReference?,
        targetPaneID: String?,
        targetWorkspaceID: String?
    ) -> AICommandContextReference {
        let base = reference ?? AICommandContextReference()
        return base.retargeted(
            targetPaneID: targetPaneID ?? base.targetPaneID.map { sanitized($0) },
            targetWorkspaceID: targetWorkspaceID ?? base.targetWorkspaceID.map { sanitized($0) }
        )
    }

    private func defaultContextReferences(from reference: AICommandContextReference) -> [AICommandContextReference] {
        guard reference.commandSpanID != nil
                || reference.targetPaneID != nil
                || reference.targetWorkspaceID != nil
                || reference.promptBoundarySequence != nil
                || reference.startBoundarySequence != nil
                || reference.outputBoundarySequence != nil
                || reference.endBoundarySequence != nil
        else {
            return []
        }
        return [reference]
    }

    private func sanitizedCapabilityRequest(
        _ request: AIAgentActionCapabilityRequest
    ) -> AIAgentActionCapabilityRequest {
        AIAgentActionCapabilityRequest(
            capability: sanitized(request.capability),
            reference: request.reference.map {
                sanitizedReference($0, targetPaneID: nil, targetWorkspaceID: nil)
            },
            reason: request.reason.map { sanitized($0) }
        )
    }

    private func auditNote(for options: Options) -> String {
        let rawOutputNote = options.includeRawOutput
            ? "raw output requested; \(options.rawOutputApproved ? "approved" : "approval required"); redacted"
            : "raw output omitted by default"
        return "\(options.auditNote); \(rawOutputNote)"
    }

    private func sanitized(_ text: String, maxTextLength: Int = 512) -> String {
        var eventLog = AIContextEventLog(maxEvents: 1, maxTextLength: maxTextLength)
        eventLog.record(source: "ai-approval-metadata", text: text)
        return eventLog.events.first?.text ?? ""
    }
}
