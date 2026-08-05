import Foundation

/// Turns one JSONL line into a displayable transcript message.
///
/// Decoding is a pure function over a string so every schema case is unit
/// testable without touching a real transcript. Unknown record types decode to
/// `nil` rather than throwing: agent transcript schemas drift between CLI
/// releases and a viewer must degrade to showing less, never to failing.
protocol AgentSessionTranscriptDecoding: Sendable {
    func decode(line: String, fallbackID: String, byteOffset: Int) -> AgentTranscriptMessage?
}

enum AgentSessionTranscriptDecoderFactory {
    static func decoder(for agent: AgentSessionKind) -> AgentSessionTranscriptDecoding {
        switch agent {
        case .claudeCode:
            return ClaudeTranscriptDecoder()
        case .codex:
            return CodexTranscriptDecoder()
        }
    }
}

/// Shared JSON coercion helpers.
enum AgentTranscriptJSON {
    static func object(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    static func record(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    /// Flattens an arbitrary tool-result payload into one output string.
    static func toolResultOutput(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        guard let items = value as? [Any] else {
            guard let record = record(value) else {
                return value.map { String(describing: $0) } ?? ""
            }
            return string(record["text"]) ?? string(record["content"]) ?? ""
        }
        return items.compactMap { item -> String? in
            if let text = item as? String {
                return text
            }
            guard let record = record(item) else {
                return nil
            }
            return string(record["text"]) ?? string(record["content"])
        }
        .joined(separator: "\n")
    }

    /// Deterministic pretty print used for the expanded tool-input body.
    static func prettyPrinted(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            return value.map { String(describing: $0) } ?? ""
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds the collapsed preview, expanded detail, and optional diff for one
/// tool call.
enum AgentTranscriptToolPresentation {
    private enum Field {
        static let filePath = "file_path"
        static let path = "path"
        static let oldString = "old_string"
        static let newString = "new_string"
        static let content = "content"
        static let command = "command"
        static let pattern = "pattern"
        static let prompt = "prompt"
        static let url = "url"
        static let edits = "edits"
    }

    private enum ToolName {
        static let edit = "Edit"
        static let write = "Write"
        static let multiEdit = "MultiEdit"
    }

    static let maximumPreviewCharacters = 120

    static func toolCall(name: String, input: Any?) -> AgentTranscriptToolCall {
        let record = AgentTranscriptJSON.record(input)
        return AgentTranscriptToolCall(
            name: name,
            preview: preview(name: name, input: record),
            detail: AgentTranscriptJSON.prettyPrinted(input),
            diff: diff(name: name, input: record)
        )
    }

    /// The single most identifying field for the tool, so a collapsed row reads
    /// like `▸ Edit  src/foo.swift`.
    static func preview(name: String, input: [String: Any]?) -> String {
        guard let input else {
            return ""
        }
        let candidates = [
            Field.filePath,
            Field.path,
            Field.command,
            Field.pattern,
            Field.url,
            Field.prompt,
        ]
        for key in candidates {
            guard let value = AgentTranscriptJSON.string(input[key]) else {
                continue
            }
            return truncatedSingleLine(value)
        }
        return ""
    }

    static func truncatedSingleLine(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? value
        guard collapsed.count > maximumPreviewCharacters else {
            return collapsed
        }
        return String(collapsed.prefix(maximumPreviewCharacters)) + "…"
    }

    /// Synthesizes a diff when the input already carries both sides of an edit.
    /// Nothing on disk is read, so the viewer stays read-only.
    static func diff(name: String, input: [String: Any]?) -> AgentTranscriptDiff? {
        guard let input else {
            return nil
        }
        let filePath = AgentTranscriptJSON.string(input[Field.filePath])
            ?? AgentTranscriptJSON.string(input[Field.path])
            ?? ""

        switch name {
        case ToolName.edit:
            return editDiff(
                filePath: filePath,
                oldString: AgentTranscriptJSON.string(input[Field.oldString]),
                newString: AgentTranscriptJSON.string(input[Field.newString])
            )
        case ToolName.write:
            guard let content = AgentTranscriptJSON.string(input[Field.content]) else {
                return nil
            }
            return AgentTranscriptDiff(filePath: filePath, lines: lines(content, kind: .added))
        case ToolName.multiEdit:
            guard let edits = input[Field.edits] as? [Any] else {
                return nil
            }
            let merged = edits.compactMap(AgentTranscriptJSON.record).flatMap { edit in
                editDiff(
                    filePath: filePath,
                    oldString: AgentTranscriptJSON.string(edit[Field.oldString]),
                    newString: AgentTranscriptJSON.string(edit[Field.newString])
                )?.lines ?? []
            }
            return merged.isEmpty ? nil : AgentTranscriptDiff(filePath: filePath, lines: merged)
        default:
            return nil
        }
    }

    private static func editDiff(
        filePath: String,
        oldString: String?,
        newString: String?
    ) -> AgentTranscriptDiff? {
        guard oldString != nil || newString != nil else {
            return nil
        }
        var lines: [AgentTranscriptDiff.Line] = []
        if let oldString {
            lines += self.lines(oldString, kind: .removed)
        }
        if let newString {
            lines += self.lines(newString, kind: .added)
        }
        return lines.isEmpty ? nil : AgentTranscriptDiff(filePath: filePath, lines: lines)
    }

    private static func lines(
        _ text: String,
        kind: AgentTranscriptDiff.LineKind
    ) -> [AgentTranscriptDiff.Line] {
        text
            .components(separatedBy: "\n")
            .map { AgentTranscriptDiff.Line(kind: kind, text: $0) }
    }
}

// MARK: - Claude Code

/// `~/.claude/projects/<slug>/<sessionId>.jsonl`.
struct ClaudeTranscriptDecoder: AgentSessionTranscriptDecoding {
    private enum RecordType {
        static let user = "user"
        static let assistant = "assistant"
    }

    private enum Field {
        static let type = "type"
        static let uuid = "uuid"
        static let timestamp = "timestamp"
        static let message = "message"
        static let content = "content"
        static let id = "id"
        static let isMeta = "isMeta"
        static let isSynthetic = "isSynthetic"
        static let isCompactSummary = "isCompactSummary"
    }

    private enum BlockType {
        static let text = "text"
        static let thinking = "thinking"
        static let toolUse = "tool_use"
        static let toolResult = "tool_result"
        static let name = "name"
        static let input = "input"
        static let isError = "is_error"
        static let fallbackToolName = "tool"
    }

    func decode(line: String, fallbackID: String, byteOffset: Int) -> AgentTranscriptMessage? {
        guard let record = AgentTranscriptJSON.object(from: line) else {
            return nil
        }
        let type = AgentTranscriptJSON.string(record[Field.type])
        guard type == RecordType.user || type == RecordType.assistant else {
            return nil
        }

        let message = AgentTranscriptJSON.record(record[Field.message])
        let decoded = Self.blocks(from: message?[Field.content])
        guard !decoded.isEmpty else {
            return nil
        }

        // Claude marks injected user turns structurally. Their tool results are
        // real output and stay; the injected prose does not.
        let isInjectedUserTurn = type == RecordType.user && [
            Field.isMeta,
            Field.isSynthetic,
            Field.isCompactSummary,
        ].contains { record[$0] as? Bool == true }
        let blocks = isInjectedUserTurn
            ? decoded.filter { if case .toolResult = $0 { return true } else { return false } }
            : decoded
        guard !blocks.isEmpty else {
            return nil
        }

        let id = AgentTranscriptJSON.string(record[Field.uuid])
            ?? AgentTranscriptJSON.string(message?[Field.id])
            ?? fallbackID
        return AgentTranscriptMessage(
            id: id,
            role: Self.role(type: type, blocks: blocks),
            blocks: blocks,
            timestamp: AgentSessionTimestampParser().date(from: record[Field.timestamp]),
            byteOffset: byteOffset
        )
    }

    private static func role(type: String?, blocks: [AgentTranscriptBlock]) -> AgentTranscriptRole {
        guard type == RecordType.user else {
            return .assistant
        }
        let onlyToolResults = blocks.allSatisfy { block in
            if case .toolResult = block { return true } else { return false }
        }
        return onlyToolResults ? .tool : .user
    }

    /// Content is either a plain string or an array of typed blocks.
    static func blocks(from content: Any?) -> [AgentTranscriptBlock] {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(text)]
        }
        guard let items = content as? [Any] else {
            return []
        }
        return items.compactMap(block(from:))
    }

    private static func block(from item: Any) -> AgentTranscriptBlock? {
        if let text = item as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(text)
        }
        guard let record = AgentTranscriptJSON.record(item) else {
            return nil
        }
        switch AgentTranscriptJSON.string(record[Field.type]) {
        case BlockType.text:
            return AgentTranscriptJSON.string(record[BlockType.text]).map(AgentTranscriptBlock.text)
        case BlockType.thinking:
            let text = AgentTranscriptJSON.string(record[BlockType.thinking])
                ?? AgentTranscriptJSON.string(record[BlockType.text])
            return text.map(AgentTranscriptBlock.text)
        case BlockType.toolUse:
            let name = AgentTranscriptJSON.string(record[BlockType.name]) ?? BlockType.fallbackToolName
            return .toolCall(AgentTranscriptToolPresentation.toolCall(
                name: name,
                input: record[BlockType.input]
            ))
        case BlockType.toolResult:
            return .toolResult(AgentTranscriptToolResult(
                output: AgentTranscriptJSON.toolResultOutput(record[Field.content]),
                isError: record[BlockType.isError] as? Bool == true
            ))
        default:
            return nil
        }
    }
}

// MARK: - Codex

/// `~/.codex/sessions/.../rollout-*.jsonl`. The record schema is treated as
/// unknown and heterogeneous, matching `CodexSessionScanner`.
struct CodexTranscriptDecoder: AgentSessionTranscriptDecoding {
    private enum RecordType {
        static let responseItem = "response_item"
        static let eventMessage = "event_msg"
        static let message = "message"
        static let userMessage = "user_message"
        static let functionCall = "function_call"
        static let functionCallOutput = "function_call_output"
    }

    private enum Field {
        static let type = "type"
        static let payload = "payload"
        static let timestamp = "timestamp"
        static let role = "role"
        static let content = "content"
        static let message = "message"
        static let name = "name"
        static let arguments = "arguments"
        static let output = "output"
        static let callID = "call_id"
        static let user = "user"
        static let assistant = "assistant"
        static let fallbackToolName = "tool"
    }

    func decode(line: String, fallbackID: String, byteOffset: Int) -> AgentTranscriptMessage? {
        guard let record = AgentTranscriptJSON.object(from: line),
              let payload = AgentTranscriptJSON.record(record[Field.payload])
        else {
            return nil
        }
        let recordType = AgentTranscriptJSON.string(record[Field.type])
        let payloadType = AgentTranscriptJSON.string(payload[Field.type])
        let timestamp = AgentSessionTimestampParser().date(from: record[Field.timestamp])
            ?? AgentSessionTimestampParser().date(from: payload[Field.timestamp])
        let identifier = AgentTranscriptJSON.string(payload[Field.callID]) ?? fallbackID

        if recordType == RecordType.eventMessage, payloadType == RecordType.userMessage {
            guard let text = AgentTranscriptJSON.string(payload[Field.message]) else {
                return nil
            }
            return AgentTranscriptMessage(
                id: identifier,
                role: .user,
                blocks: [.text(text)],
                timestamp: timestamp,
                byteOffset: byteOffset
            )
        }

        guard recordType == RecordType.responseItem else {
            return nil
        }

        switch payloadType {
        case RecordType.message:
            let role = AgentTranscriptJSON.string(payload[Field.role])
            guard role == Field.user || role == Field.assistant else {
                return nil
            }
            let blocks = ClaudeTranscriptDecoder.blocks(from: payload[Field.content])
            guard !blocks.isEmpty else {
                return nil
            }
            return AgentTranscriptMessage(
                id: identifier,
                role: role == Field.user ? .user : .assistant,
                blocks: blocks,
                timestamp: timestamp,
                byteOffset: byteOffset
            )
        case RecordType.functionCall:
            let name = AgentTranscriptJSON.string(payload[Field.name]) ?? Field.fallbackToolName
            // Codex stores arguments as a JSON string rather than an object.
            let arguments = AgentTranscriptJSON.string(payload[Field.arguments])
                .flatMap(AgentTranscriptJSON.object(from:))
            return AgentTranscriptMessage(
                id: identifier,
                role: .assistant,
                blocks: [.toolCall(AgentTranscriptToolPresentation.toolCall(
                    name: name,
                    input: arguments
                ))],
                timestamp: timestamp,
                byteOffset: byteOffset
            )
        case RecordType.functionCallOutput:
            return AgentTranscriptMessage(
                id: identifier,
                role: .tool,
                blocks: [.toolResult(AgentTranscriptToolResult(
                    output: AgentTranscriptJSON.toolResultOutput(payload[Field.output])
                ))],
                timestamp: timestamp,
                byteOffset: byteOffset
            )
        default:
            return nil
        }
    }
}
