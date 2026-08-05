import Foundation

/// Which files an agent wrote, when, and from which user prompt.
///
/// The agents already record this: every Claude `Edit`/`Write` tool call and
/// every Codex `apply_patch` result carries an absolute path, and the transcript
/// preserves the order of user prompts against those calls. Nothing else on the
/// machine joins the two, so this is the one place that does.
///
/// Extraction is a pure function over a transcript string, mirroring
/// `AgentSessionScanning.parse(contents:...)`, so every schema case is testable
/// without touching the real home directory.
///
/// Known ceiling: the caller reads transcripts through
/// `AgentSessionTranscriptReader`, which slurps files at or below
/// `fullReadThresholdBytes` and otherwise supplies a bounded head plus tail
/// window. Above that threshold the middle of a session is never seen, so this
/// under-reports writes and can lose the prompt behind a write near the window
/// boundary. That is deliberate — one observed transcript is 2 GB — and the
/// error is one-directional: a file may go unattributed, but an attribution is
/// never invented. Recent writes live in the tail window, which is exactly what
/// the explorer's recency marker needs.

// MARK: - Values

/// What one agent tool call did to a file.
enum AgentFileChangeKind: String, Equatable, Sendable {
    /// The agent supplied the whole file body: Claude `Write`, Codex `add`.
    /// Neither agent records whether the file already existed, so this is
    /// deliberately not called "created".
    case replaced
    /// A partial edit: Claude `Edit`/`MultiEdit`/`NotebookEdit`, Codex `update`.
    case edited
    /// Codex `delete`. Claude Code has no delete tool, so its transcripts never
    /// produce this.
    case deleted
}

/// One file write an agent performed, attributed to the session and to the user
/// prompt that preceded the tool call.
///
/// Privacy contract matches `AgentSessionRecord`: metadata plus a single-line
/// prompt excerpt. The edited content, the old/new strings, and the unified
/// diff the transcript carries are all read and discarded — none of them are
/// retained here or written anywhere.
struct AgentFileTouch: Equatable, Sendable {
    let agent: AgentSessionKind
    let sessionID: String
    /// Absolute path as the agent recorded it, standardized so `.` and `..`
    /// segments cannot make one file look like two.
    let absolutePath: String
    let changedAt: Date
    let kind: AgentFileChangeKind
    /// First meaningful line of the user prompt that preceded this tool call.
    /// Nil when the bounded read window began after that prompt, or when the
    /// prompt was entirely injected machine text.
    let promptExcerpt: String?
    let transcriptPath: String
}

// MARK: - Extraction

/// One agent's transcript shape, as far as file writes are concerned.
protocol AgentFileProvenanceExtracting: Sendable {
    var agent: AgentSessionKind { get }

    /// Pure parse of one transcript into the file writes it recorded, in
    /// transcript order. `contents` may be a bounded head/tail window, in which
    /// case the result is a subset and prompts before the window are lost.
    func touches(contents: String, sessionID: String, transcriptPath: String) -> [AgentFileTouch]
}

enum AgentFileProvenanceExtractorFactory {
    static func extractor(for agent: AgentSessionKind) -> any AgentFileProvenanceExtracting {
        switch agent {
        case .claudeCode:
            return ClaudeFileProvenanceExtractor()
        case .codex:
            return CodexFileProvenanceExtractor()
        }
    }

    static let all: [any AgentFileProvenanceExtracting] = AgentSessionKind.allCases.map(extractor(for:))
}

/// Shared path and prompt coercion for both extractors.
enum AgentFileProvenanceParsing {
    /// Both agents record absolute paths; a relative one would be ambiguous
    /// without the tool call's working directory, so it is dropped rather than
    /// guessed at.
    static func normalizedAbsolutePath(_ value: Any?) -> String? {
        guard let path = AgentSessionTranscriptParsing.nonEmptyString(value), path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The one line of a prompt worth showing beside a file. Reuses the session
    /// index's title rule so an injected `<context>` envelope never becomes the
    /// visible reason a file changed.
    static func promptExcerpt(from text: String?) -> String? {
        guard let text else {
            return nil
        }
        return AgentSessionTranscriptParsing.titleLine(from: text)
    }
}

// MARK: - Claude Code

/// Claude records writes as `tool_use` blocks inside an `assistant` record:
/// `Edit`, `Write`, `MultiEdit`, and `NotebookEdit` all carry an absolute path
/// in their input. The result arrives later as a `tool_result` block in a
/// following `user` record, and a failed edit (`is_error`) never touched the
/// file, so those are dropped by `tool_use_id`.
struct ClaudeFileProvenanceExtractor: AgentFileProvenanceExtracting {
    let agent = AgentSessionKind.claudeCode

    private enum RecordType {
        static let user = "user"
        static let assistant = "assistant"
    }

    private enum Field {
        static let type = "type"
        static let message = "message"
        static let content = "content"
        static let timestamp = "timestamp"
        static let role = "role"
        /// Structural markers for user turns Claude injected itself.
        static let injectedTurnFlags = ["isMeta", "isSynthetic", "isCompactSummary"]
    }

    private enum BlockType {
        static let toolUse = "tool_use"
        static let toolResult = "tool_result"
        static let text = "text"
        static let name = "name"
        static let input = "input"
        static let identifier = "id"
        static let toolUseID = "tool_use_id"
        static let isError = "is_error"
    }

    private enum ToolName {
        static let edit = "Edit"
        static let write = "Write"
        static let multiEdit = "MultiEdit"
        static let notebookEdit = "NotebookEdit"

        static func changeKind(for name: String) -> AgentFileChangeKind? {
            switch name {
            case write:
                return .replaced
            case edit, multiEdit, notebookEdit:
                return .edited
            default:
                return nil
            }
        }
    }

    private enum InputField {
        static let filePath = "file_path"
        static let notebookPath = "notebook_path"
    }

    func touches(contents: String, sessionID: String, transcriptPath: String) -> [AgentFileTouch] {
        let objects = AgentSessionTranscriptParsing.jsonObjects(in: contents)
        guard !objects.isEmpty else {
            return []
        }
        let timestamps = AgentSessionTimestampParser()
        var promptExcerpt: String?
        var touches: [AgentFileTouch] = []
        var touchIndexByToolUseID: [String: Int] = [:]
        var failedTouchIndexes: Set<Int> = []

        for object in objects {
            let type = AgentSessionTranscriptParsing.nonEmptyString(object[Field.type])
            guard type == RecordType.user || type == RecordType.assistant else {
                continue
            }
            let blocks = contentBlocks(in: object)
            markFailedResults(
                in: blocks,
                touchIndexByToolUseID: touchIndexByToolUseID,
                failedTouchIndexes: &failedTouchIndexes
            )
            guard type == RecordType.assistant else {
                if let text = userPromptText(in: object, blocks: blocks) {
                    promptExcerpt = AgentFileProvenanceParsing.promptExcerpt(from: text)
                }
                continue
            }
            let changedAt = timestamps.date(from: object[Field.timestamp])
            appendWrites(
                in: blocks,
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                changedAt: changedAt,
                promptExcerpt: promptExcerpt,
                touches: &touches,
                touchIndexByToolUseID: &touchIndexByToolUseID
            )
        }

        guard !failedTouchIndexes.isEmpty else {
            return touches
        }
        return touches.enumerated()
            .filter { !failedTouchIndexes.contains($0.offset) }
            .map(\.element)
    }

    private func contentBlocks(in object: [String: Any]) -> [[String: Any]] {
        guard let message = object[Field.message] as? [String: Any],
              let items = message[Field.content] as? [Any]
        else {
            return []
        }
        return items.compactMap { $0 as? [String: Any] }
    }

    /// A user record is a prompt only when the user actually typed it: injected
    /// turns and tool-result-only turns keep the previous prompt in force.
    private func userPromptText(in object: [String: Any], blocks: [[String: Any]]) -> String? {
        guard !Field.injectedTurnFlags.contains(where: { object[$0] as? Bool == true }) else {
            return nil
        }
        guard let message = object[Field.message] as? [String: Any] else {
            return nil
        }
        if let role = AgentSessionTranscriptParsing.nonEmptyString(message[Field.role]),
           role != RecordType.user {
            return nil
        }
        if let text = AgentSessionTranscriptParsing.nonEmptyString(message[Field.content]) {
            return text
        }
        let texts = blocks.compactMap { block -> String? in
            guard AgentSessionTranscriptParsing.nonEmptyString(block[Field.type]) == BlockType.text else {
                return nil
            }
            return AgentSessionTranscriptParsing.nonEmptyString(block[BlockType.text])
        }
        let joined = texts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func appendWrites(
        in blocks: [[String: Any]],
        sessionID: String,
        transcriptPath: String,
        changedAt: Date?,
        promptExcerpt: String?,
        touches: inout [AgentFileTouch],
        touchIndexByToolUseID: inout [String: Int]
    ) {
        for block in blocks {
            guard AgentSessionTranscriptParsing.nonEmptyString(block[Field.type]) == BlockType.toolUse,
                  let name = AgentSessionTranscriptParsing.nonEmptyString(block[BlockType.name]),
                  let kind = ToolName.changeKind(for: name),
                  let input = block[BlockType.input] as? [String: Any],
                  let path = AgentFileProvenanceParsing.normalizedAbsolutePath(input[InputField.filePath])
                      ?? AgentFileProvenanceParsing.normalizedAbsolutePath(input[InputField.notebookPath]),
                  let changedAt
            else {
                continue
            }
            if let identifier = AgentSessionTranscriptParsing.nonEmptyString(block[BlockType.identifier]) {
                touchIndexByToolUseID[identifier] = touches.count
            }
            touches.append(AgentFileTouch(
                agent: agent,
                sessionID: sessionID,
                absolutePath: path,
                changedAt: changedAt,
                kind: kind,
                promptExcerpt: promptExcerpt,
                transcriptPath: transcriptPath
            ))
        }
    }

    private func markFailedResults(
        in blocks: [[String: Any]],
        touchIndexByToolUseID: [String: Int],
        failedTouchIndexes: inout Set<Int>
    ) {
        for block in blocks {
            guard AgentSessionTranscriptParsing.nonEmptyString(block[Field.type]) == BlockType.toolResult,
                  block[BlockType.isError] as? Bool == true,
                  let identifier = AgentSessionTranscriptParsing.nonEmptyString(block[BlockType.toolUseID]),
                  let index = touchIndexByToolUseID[identifier]
            else {
                continue
            }
            failedTouchIndexes.insert(index)
        }
    }
}

// MARK: - Codex

/// Codex has no `Edit` tool. It writes files through `apply_patch` and reports
/// the outcome as an `event_msg` / `patch_apply_end` record whose `changes` map
/// is keyed by absolute path, with `add` / `update` / `delete` per entry. That
/// record is authoritative in a way the tool call is not: it carries `success`,
/// and it is emitted for every write path including the ones that arrive as a
/// shell `apply_patch` invocation rather than a structured tool call.
struct CodexFileProvenanceExtractor: AgentFileProvenanceExtracting {
    let agent = AgentSessionKind.codex

    private enum RecordType {
        static let eventMessage = "event_msg"
    }

    private enum PayloadType {
        static let userMessage = "user_message"
        static let patchApplyEnd = "patch_apply_end"
    }

    private enum Field {
        static let type = "type"
        static let payload = "payload"
        static let timestamp = "timestamp"
        static let message = "message"
        static let changes = "changes"
        static let success = "success"
    }

    private enum ChangeType {
        static let add = "add"
        static let update = "update"
        static let delete = "delete"

        static func changeKind(for value: String?) -> AgentFileChangeKind {
            switch value {
            case add:
                return .replaced
            case delete:
                return .deleted
            case update:
                return .edited
            default:
                // An unknown change verb still changed the file; reporting it as
                // an edit is the conservative reading.
                return .edited
            }
        }
    }

    func touches(contents: String, sessionID: String, transcriptPath: String) -> [AgentFileTouch] {
        let objects = AgentSessionTranscriptParsing.jsonObjects(in: contents)
        guard !objects.isEmpty else {
            return []
        }
        let timestamps = AgentSessionTimestampParser()
        var promptExcerpt: String?
        var touches: [AgentFileTouch] = []

        for object in objects {
            guard AgentSessionTranscriptParsing.nonEmptyString(object[Field.type]) == RecordType.eventMessage,
                  let payload = object[Field.payload] as? [String: Any]
            else {
                continue
            }
            switch AgentSessionTranscriptParsing.nonEmptyString(payload[Field.type]) {
            case PayloadType.userMessage:
                let text = AgentSessionTranscriptParsing.messageText(payload[Field.message])
                promptExcerpt = AgentFileProvenanceParsing.promptExcerpt(from: text) ?? promptExcerpt
            case PayloadType.patchApplyEnd:
                guard payload[Field.success] as? Bool == true,
                      let changedAt = timestamps.date(from: object[Field.timestamp])
                          ?? timestamps.date(from: payload[Field.timestamp])
                else {
                    continue
                }
                touches += changeTouches(
                    in: payload[Field.changes],
                    sessionID: sessionID,
                    transcriptPath: transcriptPath,
                    changedAt: changedAt,
                    promptExcerpt: promptExcerpt
                )
            default:
                continue
            }
        }
        return touches
    }

    /// `changes` is a JSON object, so its member order is not meaningful; paths
    /// are sorted to keep one patch's touches in a deterministic order.
    private func changeTouches(
        in changes: Any?,
        sessionID: String,
        transcriptPath: String,
        changedAt: Date,
        promptExcerpt: String?
    ) -> [AgentFileTouch] {
        guard let changes = changes as? [String: Any] else {
            return []
        }
        return changes.keys.sorted().compactMap { key in
            guard let path = AgentFileProvenanceParsing.normalizedAbsolutePath(key) else {
                return nil
            }
            let change = changes[key] as? [String: Any]
            return AgentFileTouch(
                agent: agent,
                sessionID: sessionID,
                absolutePath: path,
                changedAt: changedAt,
                kind: ChangeType.changeKind(
                    for: AgentSessionTranscriptParsing.nonEmptyString(change?[Field.type])
                ),
                promptExcerpt: promptExcerpt,
                transcriptPath: transcriptPath
            )
        }
    }
}

// MARK: - Index

/// Answers "which agent changed this file, and from which prompt?" for one
/// absolute path.
///
/// Bounded by construction: the newest `maximumTouchCount` touches survive, and
/// each path keeps at most `maximumTouchesPerFile` of them. Both caps are
/// applied newest-first, so what a file loses is its oldest history, never its
/// most recent change.
struct AgentFileProvenanceIndex: Equatable, Sendable {
    static let empty = AgentFileProvenanceIndex(touches: [])

    /// Newest first within each path.
    private let touchesByPath: [String: [AgentFileTouch]]
    /// Newest change date for each touched file and for every directory above
    /// it, so a collapsed folder can report that something inside it changed.
    private let newestChangeByPath: [String: Date]

    private static let rootPath = "/"

    init(touches: [AgentFileTouch]) {
        let newestFirst = touches
            .sorted { lhs, rhs in
                guard lhs.changedAt == rhs.changedAt else {
                    return lhs.changedAt > rhs.changedAt
                }
                guard lhs.absolutePath == rhs.absolutePath else {
                    return lhs.absolutePath < rhs.absolutePath
                }
                return lhs.sessionID < rhs.sessionID
            }
            .prefix(AppConstants.AgentProvenance.maximumTouchCount)

        var grouped: [String: [AgentFileTouch]] = [:]
        for touch in newestFirst {
            var existing = grouped[touch.absolutePath] ?? []
            guard existing.count < AppConstants.AgentProvenance.maximumTouchesPerFile else {
                continue
            }
            existing.append(touch)
            grouped[touch.absolutePath] = existing
        }
        touchesByPath = grouped

        var newest: [String: Date] = [:]
        for (path, pathTouches) in grouped {
            guard let latest = pathTouches.first?.changedAt else {
                continue
            }
            var current = path
            while !current.isEmpty, current != Self.rootPath {
                if let existing = newest[current], existing >= latest {
                    break
                }
                newest[current] = latest
                current = (current as NSString).deletingLastPathComponent
            }
        }
        newestChangeByPath = newest
    }

    /// Newest first. Empty for a file no indexed agent session wrote.
    func provenance(for url: URL) -> [AgentFileTouch] {
        provenance(forAbsolutePath: url.standardizedFileURL.path)
    }

    func provenance(forAbsolutePath absolutePath: String) -> [AgentFileTouch] {
        touchesByPath[absolutePath] ?? []
    }

    func mostRecentTouch(forAbsolutePath absolutePath: String) -> AgentFileTouch? {
        touchesByPath[absolutePath]?.first
    }

    /// Whether an indexed agent wrote this file inside `window` before `now`.
    /// A touch dated in the future is treated as recent rather than filtered:
    /// clock skew between the transcript and the reader is not the user's
    /// problem.
    func recentTouch(
        forAbsolutePath absolutePath: String,
        now: Date,
        window: TimeInterval = AppConstants.AgentProvenance.recentTouchWindowSeconds
    ) -> AgentFileTouch? {
        guard let touch = mostRecentTouch(forAbsolutePath: absolutePath),
              now.timeIntervalSince(touch.changedAt) <= window
        else {
            return nil
        }
        return touch
    }

    /// Whether the file, or anything inside the directory, was written by an
    /// indexed agent inside `window`. This is what the explorer marks: a
    /// collapsed folder has to say that something under it moved, or the marker
    /// is invisible until every folder is expanded.
    func hasRecentChange(
        atOrUnder absolutePath: String,
        now: Date,
        window: TimeInterval = AppConstants.AgentProvenance.recentTouchWindowSeconds
    ) -> Bool {
        guard let changedAt = newestChangeByPath[absolutePath] else {
            return false
        }
        return now.timeIntervalSince(changedAt) <= window
    }

    var touchedFileCount: Int {
        touchesByPath.count
    }

    var touchCount: Int {
        touchesByPath.values.reduce(0) { $0 + $1.count }
    }

    var isEmpty: Bool {
        touchesByPath.isEmpty
    }
}
