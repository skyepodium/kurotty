import Foundation

/// Pure quick-command rules: normalization, limits, scope filtering, the
/// multi-line flattening contract, and the dispatch payload shape.
///
/// Everything here is deliberately free of AppKit, the filesystem, and the
/// main actor so it can be tested directly.
enum QuickCommandNormalizer {

    // MARK: - Normalization

    /// Normalizes decoded wire records into bounded, de-duplicated commands.
    ///
    /// Incomplete rows are preserved on purpose: the editor saves on every
    /// keystroke, so a row whose name or body is still empty must survive the
    /// round trip. A record is dropped only when it carries none of the
    /// `name`, `command`, or `prompt` fields at all.
    static func normalize(records: [QuickCommandRecord]) -> [QuickCommand] {
        var normalized: [QuickCommand] = []
        var seenIdentifiers: Set<String> = []

        for record in records {
            let hasName = record.name != nil
            let hasCommand = record.command != nil
            let hasPrompt = record.prompt != nil
            guard hasName || hasCommand || hasPrompt else {
                continue
            }

            let identifier = uniqueIdentifier(
                requested: record.id,
                fallbackIndex: normalized.count + 1,
                taken: &seenIdentifiers
            )
            let name = String(
                (record.name ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(AppConstants.QuickCommands.maximumNameCharacterCount)
            )

            normalized.append(
                QuickCommand(
                    id: identifier,
                    name: name,
                    keyboardShortcut: normalizedShortcut(record.shortcut),
                    scope: normalizedScope(record.scope),
                    action: normalizedAction(record)
                )
            )

            if normalized.count >= AppConstants.QuickCommands.maximumCommandCount {
                break
            }
        }

        return normalized
    }

    /// Re-normalizes already-typed commands, used after an editor mutation so
    /// in-memory state and the persisted file can never disagree.
    static func normalize(_ commands: [QuickCommand]) -> [QuickCommand] {
        normalize(records: commands.map(record(for:)))
    }

    static func record(for command: QuickCommand) -> QuickCommandRecord {
        var record = QuickCommandRecord(
            id: command.id,
            name: command.name,
            shortcut: command.keyboardShortcut,
            scope: scopeRecord(for: command.scope),
            action: command.action.rawValue
        )
        switch command.action {
        case let .terminalCommand(text, appendEnter):
            record.command = text
            record.appendEnter = appendEnter
        case let .agentPrompt(text, agent):
            record.prompt = text
            record.agent = agent
        }
        return record
    }

    private static func normalizedAction(_ record: QuickCommandRecord) -> QuickCommandAction {
        guard record.action == AppConstants.QuickCommands.agentPromptActionRawValue else {
            let text = String(
                trimmingTrailingWhitespace(record.command ?? "")
                    .prefix(AppConstants.QuickCommands.maximumTerminalTextCharacterCount)
            )
            // Safety default differs from the Orca reference on purpose: an
            // absent flag must never mean "executes" in Kurotty.
            return .terminalCommand(text: text, appendEnter: record.appendEnter ?? false)
        }
        let prompt = String(
            trimmingTrailingWhitespace(record.prompt ?? "")
                .prefix(AppConstants.QuickCommands.maximumAgentPromptCharacterCount)
        )
        let agent = record.agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent, !agent.isEmpty else {
            return .agentPrompt(text: prompt, agent: nil)
        }
        return .agentPrompt(
            text: prompt,
            agent: String(agent.prefix(AppConstants.QuickCommands.maximumAgentNameCharacterCount))
        )
    }

    static func normalizedScope(_ record: QuickCommandScopeRecord?) -> QuickCommandScope {
        guard let record, record.type == AppConstants.QuickCommands.directoryScopeRawValue else {
            return .global
        }
        let path = standardizedDirectoryPath(record.path ?? "")
        guard !path.isEmpty else {
            return .global
        }
        return .directory(
            path: String(path.prefix(AppConstants.QuickCommands.maximumDirectoryPathCharacterCount))
        )
    }

    static func scopeRecord(for scope: QuickCommandScope) -> QuickCommandScopeRecord {
        switch scope {
        case .global:
            return QuickCommandScopeRecord(type: AppConstants.QuickCommands.globalScopeRawValue)
        case let .directory(path):
            return QuickCommandScopeRecord(
                type: AppConstants.QuickCommands.directoryScopeRawValue,
                path: path
            )
        }
    }

    private static func normalizedShortcut(_ shortcut: String?) -> String? {
        guard let trimmed = shortcut?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return String(trimmed.prefix(AppConstants.QuickCommands.maximumShortcutCharacterCount))
    }

    private static func uniqueIdentifier(
        requested: String?,
        fallbackIndex: Int,
        taken: inout Set<String>
    ) -> String {
        let requestedIdentifier = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = requestedIdentifier.isEmpty
            ? "\(AppConstants.QuickCommands.identifierPrefix)\(fallbackIndex)"
            : requestedIdentifier
        var identifier = String(base.prefix(AppConstants.QuickCommands.maximumIdentifierCharacterCount))
        var suffix = 2
        while taken.contains(identifier) {
            let truncated = base.prefix(AppConstants.QuickCommands.maximumIdentifierCharacterCount - 4)
            identifier = "\(truncated)-\(suffix)"
            suffix += 1
        }
        taken.insert(identifier)
        return identifier
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    // MARK: - Mutation merge

    static func apply(
        _ mutation: QuickCommandMutation,
        to commands: [QuickCommand]
    ) -> [QuickCommand] {
        switch mutation {
        case let .delete(id):
            return commands.filter { $0.id != id }
        case let .upsert(command):
            guard let index = commands.firstIndex(where: { $0.id == command.id }) else {
                guard commands.count < AppConstants.QuickCommands.maximumCommandCount else {
                    return commands
                }
                return commands + [command]
            }
            var updated = commands
            updated[index] = command
            return updated
        }
    }

    // MARK: - Multi-line flattening

    /// Joins multi-line terminal text into a single shell command list.
    ///
    /// Copied from `flattenTerminalQuickCommand` in the Orca reference. Raw
    /// `\n` written into a PTY while a foreground program is running is
    /// consumed as *stdin* by that program instead of being run as commands,
    /// so the lines are joined with `"; "` and sent as one command list.
    static func flattenedTerminalText(_ text: String) -> String {
        guard containsLineBreak(text) else {
            return text
        }
        return joinedLines(in: text, separator: AppConstants.QuickCommands.shellCommandListSeparator)
    }

    /// Agent prompts keep their words but must not carry a line break, because
    /// a newline inside an agent TUI submits the prompt early.
    static func flattenedAgentPrompt(_ text: String) -> String {
        guard containsLineBreak(text) else {
            return text
        }
        return joinedLines(in: text, separator: AppConstants.QuickCommands.agentPromptLineSeparator)
    }

    static func flattened(_ command: QuickCommand) -> QuickCommand {
        var flattened = command
        switch command.action {
        case let .terminalCommand(text, appendEnter):
            flattened.action = .terminalCommand(
                text: flattenedTerminalText(text),
                appendEnter: appendEnter
            )
        case let .agentPrompt(text, agent):
            flattened.action = .agentPrompt(text: flattenedAgentPrompt(text), agent: agent)
        }
        return flattened
    }

    static func containsLineBreak(_ text: String) -> Bool {
        text.contains { AppConstants.QuickCommands.lineBreakCharacters.contains($0) }
    }

    private static func joinedLines(in text: String, separator: String) -> String {
        text
            .split(whereSeparator: { AppConstants.QuickCommands.lineBreakCharacters.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    // MARK: - Dispatch payload

    /// The exact bytes a quick command contributes to the pane, plus whether
    /// sending them executes. `executes` is the dispatcher's approval key.
    struct DispatchPayload: Equatable {
        let text: String
        let executes: Bool
    }

    /// Returns nil for an incomplete command so an empty row can never send.
    static func dispatchPayload(for command: QuickCommand) -> DispatchPayload? {
        let flattened = flattened(command)
        let body = flattened.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return nil
        }
        guard flattened.executesOnDispatch else {
            return DispatchPayload(text: body, executes: false)
        }
        return DispatchPayload(text: body + AppConstants.QuickCommands.enterSequence, executes: true)
    }

    // MARK: - Directory scope filtering

    /// Pure visibility rule: a directory-scoped command is offered only when
    /// the active pane's working directory is at or below its directory.
    static func isVisible(_ command: QuickCommand, inWorkingDirectory cwd: String?) -> Bool {
        switch command.scope {
        case .global:
            return true
        case let .directory(path):
            guard let cwd else {
                return false
            }
            return isDirectory(cwd, atOrBelow: path)
        }
    }

    static func visibleCommands(
        _ commands: [QuickCommand],
        inWorkingDirectory cwd: String?
    ) -> [QuickCommand] {
        commands.filter { isVisible($0, inWorkingDirectory: cwd) }
    }

    static func isDirectory(_ cwd: String, atOrBelow root: String) -> Bool {
        let cwdComponents = pathComponents(of: cwd)
        let rootComponents = pathComponents(of: root)
        guard !cwdComponents.isEmpty, !rootComponents.isEmpty else {
            return false
        }
        guard cwdComponents.count >= rootComponents.count else {
            return false
        }
        return Array(cwdComponents.prefix(rootComponents.count)) == rootComponents
    }

    static func standardizedDirectoryPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return (trimmed as NSString).expandingTildeInPath as String
    }

    private static func pathComponents(of path: String) -> [String] {
        standardizedDirectoryPath(path)
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != "." }
    }
}
