import Foundation

/// Who produced a transcript turn.
enum AgentTranscriptRole: String, Equatable, Sendable {
    case user
    case assistant
    /// A turn whose entire payload is tool results.
    case tool
    /// Harness-authored status such as an interruption notice.
    case system
}

/// One rendered piece of a turn.
///
/// Tool inputs are flattened into display strings at decode time rather than
/// carried as loose JSON: the viewer is read-only, so nothing downstream needs
/// the structured payload, and pre-rendering keeps the model `Equatable` and
/// cheap to diff when the tail grows.
enum AgentTranscriptBlock: Equatable, Sendable {
    case text(String)
    case toolCall(AgentTranscriptToolCall)
    case toolResult(AgentTranscriptToolResult)

    var isTool: Bool {
        switch self {
        case .text:
            return false
        case .toolCall, .toolResult:
            return true
        }
    }
}

struct AgentTranscriptToolCall: Equatable, Sendable {
    /// Tool name as the agent recorded it, for example `Edit`.
    var name: String
    /// One-line summary shown on the collapsed row, usually a file path.
    var preview: String
    /// Pretty-printed input shown when the row expands.
    var detail: String
    /// Synthesized diff for `Edit`/`Write`-shaped inputs.
    var diff: AgentTranscriptDiff?

    init(name: String, preview: String = "", detail: String = "", diff: AgentTranscriptDiff? = nil) {
        self.name = name
        self.preview = preview
        self.detail = detail
        self.diff = diff
    }
}

struct AgentTranscriptToolResult: Equatable, Sendable {
    var output: String
    var isError: Bool

    init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }
}

/// Minimal diff view synthesized from an `Edit`/`Write` tool input.
///
/// This is not a real diff algorithm: `Edit` already carries the exact old and
/// new text, so the removed and added blocks are simply the two sides. Anything
/// more would need the file contents, which a read-only viewer must not read.
struct AgentTranscriptDiff: Equatable, Sendable {
    enum LineKind: Equatable, Sendable {
        case removed
        case added
    }

    struct Line: Equatable, Sendable {
        var kind: LineKind
        var text: String
    }

    var filePath: String
    var lines: [Line]

    var removedCount: Int {
        lines.count { $0.kind == .removed }
    }

    var addedCount: Int {
        lines.count { $0.kind == .added }
    }
}

/// One decoded transcript record.
struct AgentTranscriptMessage: Equatable, Sendable {
    /// Record uuid when present, otherwise a path+offset fallback so the row
    /// identity stays stable across incremental appends.
    var id: String
    var role: AgentTranscriptRole
    var blocks: [AgentTranscriptBlock]
    var timestamp: Date?
    /// Byte offset of the record's first byte in the transcript file.
    var byteOffset: Int

    init(
        id: String,
        role: AgentTranscriptRole,
        blocks: [AgentTranscriptBlock],
        timestamp: Date? = nil,
        byteOffset: Int = 0
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.byteOffset = byteOffset
    }

    var text: String {
        blocks.compactMap { block in
            guard case let .text(text) = block else {
                return nil
            }
            return text
        }
        .joined(separator: "\n")
    }

    var isToolOnly: Bool {
        !blocks.isEmpty && blocks.allSatisfy(\.isTool)
    }
}

/// Fallback identity for records without a uuid: stable for a given file and
/// record offset, which is all the viewer needs to keep rows in place.
enum AgentTranscriptFallbackID {
    static func make(filePath: String, byteOffset: Int) -> String {
        "\(filePath)#\(byteOffset)"
    }
}
