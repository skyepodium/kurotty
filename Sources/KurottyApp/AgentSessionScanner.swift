import Foundation

/// One agent's on-disk transcript layout.
///
/// Parsing is deliberately split from file walking: `parse(contents:...)` is a
/// pure function over a transcript string so it can be unit tested without
/// touching the real home directory, while `sessionFileURLs(rootURL:)` is the
/// only part that reaches the filesystem and always takes an injected root.
protocol AgentSessionScanning: Sendable {
    var agent: AgentSessionKind { get }

    /// Root directory the agent writes transcripts into, derived from an
    /// injected home directory so tests can point at a temporary tree.
    func rootURL(homeDirectory: URL) -> URL

    /// Transcript files under `rootURL`, newest-modified first. Never called
    /// on the main actor.
    func sessionFileURLs(rootURL: URL, fileManager: FileManager) -> [URL]

    /// Pure parse of one transcript. `isTranscriptTruncated` is true when the
    /// caller only supplied a bounded head/tail window of a large file.
    func parse(
        contents: String,
        fileURL: URL,
        modifiedAt: Date,
        isTranscriptTruncated: Bool
    ) -> AgentSessionRecord?
}

extension AgentSessionScanning {
    /// Convenience for tests and callers holding raw lines.
    func parse(
        lines: [String],
        fileURL: URL,
        modifiedAt: Date,
        isTranscriptTruncated: Bool = false
    ) -> AgentSessionRecord? {
        parse(
            contents: lines.joined(separator: "\n"),
            fileURL: fileURL,
            modifiedAt: modifiedAt,
            isTranscriptTruncated: isTranscriptTruncated
        )
    }
}

// MARK: - Shared JSONL helpers

/// Pure helpers shared by the scanners: line splitting, timestamp parsing, and
/// defensive extraction from heterogeneous JSON objects.
enum AgentSessionTranscriptParsing {
    /// Decoded JSON objects for the parseable lines. Malformed or partial
    /// lines (always possible at a bounded-read boundary) are skipped rather
    /// than failing the whole file.
    static func jsonObjects(in contents: String) -> [[String: Any]] {
        contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
                    return nil
                }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Flattens agent message content, which is either a plain string or an
    /// array of typed content blocks carrying a `text` field.
    static func messageText(_ content: Any?) -> String? {
        if let text = nonEmptyString(content) {
            return text
        }
        guard let blocks = content as? [Any] else {
            return nil
        }
        let texts = blocks.compactMap { block -> String? in
            guard let block = block as? [String: Any] else {
                return nonEmptyString(block)
            }
            return nonEmptyString(block["text"])
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Depth-bounded search for a working-directory field anywhere in a
    /// heterogeneous record. Codex rollout records nest theirs under `payload`
    /// and the schema is not a stable contract.
    static func workingDirectory(in object: [String: Any], depth: Int = 0) -> String? {
        guard depth <= AppConstants.AgentSessions.maximumJSONSearchDepth else {
            return nil
        }
        for key in workingDirectoryKeys {
            if let value = nonEmptyString(object[key]), value.hasPrefix("/") {
                return value
            }
        }
        for value in object.values {
            guard let nested = value as? [String: Any],
                  let found = workingDirectory(in: nested, depth: depth + 1)
            else {
                continue
            }
            return found
        }
        return nil
    }

    private static let workingDirectoryKeys = ["cwd", "working_directory", "workingDirectory"]

    /// First non-empty line, collapsed and length-capped, used as a fallback
    /// session title when the agent recorded no title of its own.
    static func titleLine(from prompt: String) -> String? {
        let line = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { candidate in
                // Injected context blocks and slash-command envelopes are
                // machine text, not something the user would recognize.
                !candidate.isEmpty && !candidate.hasPrefix("<")
            }
        guard let line else {
            return nil
        }
        return truncated(line, maximumCharacters: AppConstants.AgentSessions.maximumTitleCharacters)
    }

    static func truncated(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else {
            return value
        }
        return String(value.prefix(maximumCharacters)) + "…"
    }
}

/// ISO8601 timestamps appear with and without fractional seconds across agent
/// versions, so both shapes are tried. Instances are created per parse call and
/// never shared across threads.
struct AgentSessionTimestampParser {
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()

    init() {
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from value: Any?) -> Date? {
        guard let text = AgentSessionTranscriptParsing.nonEmptyString(value) else {
            return nil
        }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}

/// Accumulates the min/max timestamps observed while scanning a transcript.
private struct AgentSessionTimestampRange {
    private(set) var earliest: Date?
    private(set) var latest: Date?

    mutating func observe(_ date: Date?) {
        guard let date else {
            return
        }
        if earliest == nil || date < earliest! {
            earliest = date
        }
        if latest == nil || date > latest! {
            latest = date
        }
    }
}

// MARK: - Claude Code

/// `~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`, one JSON object per line.
struct ClaudeSessionScanner: AgentSessionScanning {
    let agent = AgentSessionKind.claudeCode

    private enum RecordType {
        static let user = "user"
        static let assistant = "assistant"
        static let aiTitle = "ai-title"
        static let customTitle = "custom-title"
        static let lastPrompt = "last-prompt"
    }

    private enum Field {
        static let type = "type"
        static let sessionID = "sessionId"
        static let cwd = "cwd"
        static let gitBranch = "gitBranch"
        static let timestamp = "timestamp"
        static let message = "message"
        static let content = "content"
        static let role = "role"
        static let aiTitle = "aiTitle"
        static let customTitle = "customTitle"
        static let lastPrompt = "lastPrompt"
    }

    func rootURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(AppConstants.AgentSessions.claudeProjectsRelativePath)
    }

    func sessionFileURLs(rootURL: URL, fileManager: FileManager = .default) -> [URL] {
        AgentSessionFileWalker.transcriptURLs(
            rootURL: rootURL,
            fileManager: fileManager,
            isTranscript: { url in
                url.pathExtension == AppConstants.AgentSessions.transcriptFileExtension
            }
        )
    }

    func parse(
        contents: String,
        fileURL: URL,
        modifiedAt: Date,
        isTranscriptTruncated: Bool
    ) -> AgentSessionRecord? {
        let objects = AgentSessionTranscriptParsing.jsonObjects(in: contents)
        guard !objects.isEmpty else {
            return nil
        }

        let timestamps = AgentSessionTimestampParser()
        var range = AgentSessionTimestampRange()
        var sessionID: String?
        var cwd: String?
        var gitBranch: String?
        var aiTitle: String?
        var customTitle: String?
        var lastPrompt: String?
        var firstUserPrompt: String?
        var messageCount = 0

        for object in objects {
            let type = AgentSessionTranscriptParsing.nonEmptyString(object[Field.type])
            sessionID = sessionID ?? AgentSessionTranscriptParsing.nonEmptyString(object[Field.sessionID])

            switch type {
            case RecordType.aiTitle:
                aiTitle = AgentSessionTranscriptParsing.nonEmptyString(object[Field.aiTitle]) ?? aiTitle
            case RecordType.customTitle:
                customTitle = AgentSessionTranscriptParsing.nonEmptyString(object[Field.customTitle]) ?? customTitle
            case RecordType.lastPrompt:
                lastPrompt = AgentSessionTranscriptParsing.nonEmptyString(object[Field.lastPrompt]) ?? lastPrompt
            case RecordType.user, RecordType.assistant:
                messageCount += 1
                range.observe(timestamps.date(from: object[Field.timestamp]))
                cwd = cwd ?? AgentSessionTranscriptParsing.nonEmptyString(object[Field.cwd])
                gitBranch = gitBranch ?? AgentSessionTranscriptParsing.nonEmptyString(object[Field.gitBranch])
                if type == RecordType.user, firstUserPrompt == nil {
                    firstUserPrompt = userPrompt(in: object)
                }
            default:
                range.observe(timestamps.date(from: object[Field.timestamp]))
                cwd = cwd ?? AgentSessionTranscriptParsing.nonEmptyString(object[Field.cwd])
            }
        }

        let resolvedSessionID = sessionID ?? fileURL.deletingPathExtension().lastPathComponent
        guard !resolvedSessionID.isEmpty else {
            return nil
        }

        let title = customTitle
            ?? aiTitle
            ?? firstUserPrompt.flatMap(AgentSessionTranscriptParsing.titleLine)
            ?? lastPrompt.flatMap(AgentSessionTranscriptParsing.titleLine)
            ?? resolvedSessionID

        return AgentSessionRecord(
            agent: agent,
            sessionID: resolvedSessionID,
            title: title,
            cwd: cwd ?? "",
            gitBranch: gitBranch,
            updatedAt: range.latest ?? modifiedAt,
            createdAt: range.earliest ?? range.latest ?? modifiedAt,
            messageCount: messageCount,
            isTranscriptTruncated: isTranscriptTruncated,
            firstUserPrompt: firstUserPrompt.map(cappedPrompt),
            lastUserPrompt: (lastPrompt ?? firstUserPrompt).map(cappedPrompt),
            filePath: fileURL.path
        )
    }

    private func userPrompt(in object: [String: Any]) -> String? {
        guard let message = object[Field.message] as? [String: Any] else {
            return AgentSessionTranscriptParsing.messageText(object[Field.message])
        }
        if let role = AgentSessionTranscriptParsing.nonEmptyString(message[Field.role]), role != RecordType.user {
            return nil
        }
        return AgentSessionTranscriptParsing.messageText(message[Field.content])
    }

    private func cappedPrompt(_ value: String) -> String {
        AgentSessionTranscriptParsing.truncated(
            value,
            maximumCharacters: AppConstants.AgentSessions.maximumPromptCharacters
        )
    }
}

// MARK: - Codex

/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`.
///
/// The record schema is treated as unknown and heterogeneous: the session id
/// comes from the filename, the working directory from a depth-bounded search
/// for a cwd-ish field, and the title from the first user text found.
struct CodexSessionScanner: AgentSessionScanning {
    let agent = AgentSessionKind.codex

    private enum RecordType {
        static let sessionMeta = "session_meta"
        static let eventMessage = "event_msg"
        static let responseItem = "response_item"
        static let userMessage = "user_message"
        static let message = "message"
    }

    private enum Field {
        static let type = "type"
        static let payload = "payload"
        static let timestamp = "timestamp"
        static let role = "role"
        static let content = "content"
        static let message = "message"
        static let user = "user"
        static let assistant = "assistant"
    }

    private enum FileName {
        static let uuidGroupCount = 5
        static let uuidGroupLengths = [8, 4, 4, 4, 12]
    }

    func rootURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(AppConstants.AgentSessions.codexSessionsRelativePath)
    }

    func sessionFileURLs(rootURL: URL, fileManager: FileManager = .default) -> [URL] {
        AgentSessionFileWalker.transcriptURLs(
            rootURL: rootURL,
            fileManager: fileManager,
            isTranscript: { url in
                url.pathExtension == AppConstants.AgentSessions.transcriptFileExtension
                    && url.lastPathComponent.hasPrefix(AppConstants.AgentSessions.codexRolloutFileNamePrefix)
            }
        )
    }

    /// Session identity comes from the trailing UUID in the rollout filename.
    /// Falls back to the filename without its rollout prefix when the name
    /// does not carry a well-formed UUID.
    static func sessionID(fromFileName fileName: String) -> String {
        var base = fileName
        if base.hasSuffix("." + AppConstants.AgentSessions.transcriptFileExtension) {
            base = String(base.dropLast(AppConstants.AgentSessions.transcriptFileExtension.count + 1))
        }
        if base.hasPrefix(AppConstants.AgentSessions.codexRolloutFileNamePrefix) {
            base = String(base.dropFirst(AppConstants.AgentSessions.codexRolloutFileNamePrefix.count))
        }
        let components = base.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= FileName.uuidGroupCount else {
            return base
        }
        let candidate = components.suffix(FileName.uuidGroupCount)
        let isUUIDShaped = zip(candidate, FileName.uuidGroupLengths).allSatisfy { group, length in
            group.count == length && group.allSatisfy(\.isHexDigit)
        }
        guard isUUIDShaped else {
            return base
        }
        return candidate.joined(separator: "-")
    }

    func parse(
        contents: String,
        fileURL: URL,
        modifiedAt: Date,
        isTranscriptTruncated: Bool
    ) -> AgentSessionRecord? {
        let objects = AgentSessionTranscriptParsing.jsonObjects(in: contents)
        guard !objects.isEmpty else {
            return nil
        }

        let timestamps = AgentSessionTimestampParser()
        var range = AgentSessionTimestampRange()
        var cwd: String?
        // `event_msg`/`user_message` carries what the user actually typed,
        // while `response_item` user messages also carry injected context such
        // as workspace and plugin blocks. Track them separately so a title
        // never comes from injected text when a typed prompt exists.
        var firstTypedPrompt: String?
        var lastTypedPrompt: String?
        var firstTranscriptPrompt: String?
        var lastTranscriptPrompt: String?
        var messageCount = 0

        for object in objects {
            range.observe(timestamps.date(from: object[Field.timestamp]))
            let payload = object[Field.payload] as? [String: Any]
            if cwd == nil {
                cwd = AgentSessionTranscriptParsing.workingDirectory(in: object)
            }
            guard let payload else {
                continue
            }
            range.observe(timestamps.date(from: payload[Field.timestamp]))

            let recordType = AgentSessionTranscriptParsing.nonEmptyString(object[Field.type])
            let payloadType = AgentSessionTranscriptParsing.nonEmptyString(payload[Field.type])

            if recordType == RecordType.eventMessage, payloadType == RecordType.userMessage {
                if let text = AgentSessionTranscriptParsing.messageText(payload[Field.message]) {
                    firstTypedPrompt = firstTypedPrompt ?? text
                    lastTypedPrompt = text
                }
                continue
            }

            guard recordType == RecordType.responseItem, payloadType == RecordType.message else {
                continue
            }
            let role = AgentSessionTranscriptParsing.nonEmptyString(payload[Field.role])
            guard role == Field.user || role == Field.assistant else {
                continue
            }
            messageCount += 1
            guard role == Field.user,
                  let text = AgentSessionTranscriptParsing.messageText(payload[Field.content])
            else {
                continue
            }
            firstTranscriptPrompt = firstTranscriptPrompt ?? text
            lastTranscriptPrompt = text
        }

        let sessionID = Self.sessionID(fromFileName: fileURL.lastPathComponent)
        guard !sessionID.isEmpty else {
            return nil
        }
        let firstUserPrompt = firstTypedPrompt ?? firstTranscriptPrompt
        let lastUserPrompt = lastTypedPrompt ?? lastTranscriptPrompt
        let title = firstUserPrompt.flatMap(AgentSessionTranscriptParsing.titleLine) ?? sessionID

        return AgentSessionRecord(
            agent: agent,
            sessionID: sessionID,
            title: title,
            cwd: cwd ?? "",
            gitBranch: nil,
            updatedAt: range.latest ?? modifiedAt,
            createdAt: range.earliest ?? range.latest ?? modifiedAt,
            messageCount: messageCount,
            isTranscriptTruncated: isTranscriptTruncated,
            firstUserPrompt: firstUserPrompt.map(cappedPrompt),
            lastUserPrompt: lastUserPrompt.map(cappedPrompt),
            filePath: fileURL.path
        )
    }

    private func cappedPrompt(_ value: String) -> String {
        AgentSessionTranscriptParsing.truncated(
            value,
            maximumCharacters: AppConstants.AgentSessions.maximumPromptCharacters
        )
    }
}

// MARK: - File walking

/// Filesystem half of a scan. Never called on the main actor: the store runs
/// every walk on a detached task.
enum AgentSessionFileWalker {
    static func transcriptURLs(
        rootURL: URL,
        fileManager: FileManager = .default,
        isTranscript: (URL) -> Bool
    ) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = fileManager.enumerator(
                  at: rootURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard urls.count < AppConstants.AgentSessions.maximumScannedFileCount else {
                break
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  isTranscript(url)
            else {
                continue
            }
            urls.append(url)
        }
        return urls
    }
}

/// Bounded transcript reads.
///
/// Strategy: files at or below `fullReadThresholdBytes` are read whole. Larger
/// transcripts are never slurped; instead a head window and a tail window of
/// `boundedReadWindowBytes` each are read and concatenated, because every field
/// the index needs lives either at the start (session id, cwd, git branch,
/// first prompt) or at the end (ai-title, last-prompt, latest timestamp). The
/// partial line at each window boundary is dropped by the JSONL parser, and the
/// resulting record is flagged `isTranscriptTruncated` so the message count is
/// presented as a lower bound. Files above `maximumTranscriptBytes` are skipped
/// entirely.
enum AgentSessionTranscriptReader {
    struct Result: Sendable {
        let contents: String
        let isTruncated: Bool
    }

    static func read(fileURL: URL, sizeBytes: Int) -> Result? {
        guard sizeBytes > 0, sizeBytes <= AppConstants.AgentSessions.maximumTranscriptBytes else {
            return nil
        }
        guard sizeBytes > AppConstants.AgentSessions.fullReadThresholdBytes else {
            guard let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            return Result(contents: decoded(data), isTruncated: false)
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        let window = AppConstants.AgentSessions.boundedReadWindowBytes
        guard let head = try? handle.read(upToCount: window) else {
            return nil
        }
        let tailOffset = UInt64(max(0, sizeBytes - window))
        guard (try? handle.seek(toOffset: tailOffset)) != nil,
              let tail = try? handle.readToEnd()
        else {
            return Result(contents: decoded(head), isTruncated: true)
        }
        return Result(contents: decoded(head) + "\n" + decoded(tail), isTruncated: true)
    }

    /// Transcripts are UTF-8; a bounded window can split a multi-byte scalar,
    /// so lossy decoding keeps the surrounding lines usable.
    private static func decoded(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
