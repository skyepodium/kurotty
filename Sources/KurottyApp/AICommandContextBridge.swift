import Foundation

struct AICommandContextBridge {
    struct CommandContext: Equatable {
        let command: String
        let output: String?
        let cwd: String?
        let exitCode: Int?
        let startedAt: Date?
        let endedAt: Date?

        init(
            command: String,
            output: String? = nil,
            cwd: String? = nil,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil
        ) {
            self.command = command
            self.output = output
            self.cwd = cwd
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.endedAt = endedAt
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
                endedAt: endedAt
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
        persistenceScope: AIAgentActionApprovalMetadata.PersistenceScope = .oneTime,
        maxContextSummaryLength: Int = 320
    ) -> AIAgentActionApprovalMetadata {
        AIAgentActionApprovalMetadata(
            actor: sanitized(actor),
            targetPaneID: targetPaneID.map { sanitized($0) },
            targetWorkspaceID: targetWorkspaceID.map { sanitized($0) },
            cwd: context.cwd.map { sanitized($0) },
            capability: sanitized(capability),
            persistenceScope: persistenceScope,
            contextSummary: sanitized(
                metadataText(for: context, includesOutput: false),
                maxTextLength: maxContextSummaryLength
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

        return lines.joined(separator: "\n")
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
