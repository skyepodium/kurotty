import Foundation

/// Token counts for one agent session, read out of the transcripts the session
/// index already scans. No API call and no network: the numbers are whatever
/// the agent itself wrote to disk.
struct AgentTokenUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    /// Tokens served from the prompt cache. Billed differently from fresh input
    /// everywhere it appears, so it stays a separate column rather than being
    /// folded into `inputTokens`.
    var cacheReadTokens: Int
    /// Tokens written into the prompt cache.
    var cacheWriteTokens: Int
    /// The last model seen in the transcript. A session can switch models, and
    /// the most recent one is what the next turn will bill against.
    var model: String?

    static let zero = AgentTokenUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        model: nil
    )

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
    }

    var isEmpty: Bool {
        totalTokens == 0
    }

    /// Sums two increments. The right-hand model wins so a session that
    /// switched models reports the one it ended on.
    static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            model: rhs.model ?? lhs.model
        )
    }
}

/// Reads token counts out of a transcript record.
///
/// The two agents report in opposite shapes and mixing them up is the whole
/// risk here: Claude writes a fresh `usage` block on every assistant message,
/// so those are summed, while Codex writes a running total on every
/// `token_count` event, so the last one is taken and summing would multiply the
/// real number by the event count.
enum AgentTokenUsageParsing {
    private enum ClaudeField {
        static let message = "message"
        static let usage = "usage"
        static let model = "model"
        static let inputTokens = "input_tokens"
        static let outputTokens = "output_tokens"
        static let cacheReadTokens = "cache_read_input_tokens"
        static let cacheWriteTokens = "cache_creation_input_tokens"
    }

    private enum CodexField {
        static let info = "info"
        static let totalUsage = "total_token_usage"
        static let inputTokens = "input_tokens"
        static let outputTokens = "output_tokens"
        static let cachedInputTokens = "cached_input_tokens"
    }

    /// One assistant message's own consumption. Nil when the record carries no
    /// usage block, which is every user and system record.
    static func claudeIncrement(in object: [String: Any]) -> AgentTokenUsage? {
        guard let message = object[ClaudeField.message] as? [String: Any],
              let usage = message[ClaudeField.usage] as? [String: Any]
        else {
            return nil
        }
        let increment = AgentTokenUsage(
            inputTokens: integer(usage[ClaudeField.inputTokens]),
            outputTokens: integer(usage[ClaudeField.outputTokens]),
            cacheReadTokens: integer(usage[ClaudeField.cacheReadTokens]),
            cacheWriteTokens: integer(usage[ClaudeField.cacheWriteTokens]),
            model: AgentSessionTranscriptParsing.nonEmptyString(message[ClaudeField.model])
        )
        return increment.isEmpty && increment.model == nil ? nil : increment
    }

    /// The session's running total as of this event. Later events supersede
    /// earlier ones; they are not added together.
    ///
    /// Codex reports cached input inside `input_tokens` rather than beside it,
    /// so the cached part is subtracted back out to keep `inputTokens` meaning
    /// the same thing it does for Claude: input that was not served from cache.
    static func codexRunningTotal(in payload: [String: Any]) -> AgentTokenUsage? {
        guard let info = payload[CodexField.info] as? [String: Any],
              let total = info[CodexField.totalUsage] as? [String: Any]
        else {
            return nil
        }
        let cached = integer(total[CodexField.cachedInputTokens])
        let input = integer(total[CodexField.inputTokens])
        let usage = AgentTokenUsage(
            inputTokens: max(0, input - cached),
            outputTokens: integer(total[CodexField.outputTokens]),
            cacheReadTokens: cached,
            cacheWriteTokens: 0,
            model: nil
        )
        return usage.isEmpty ? nil : usage
    }

    private static func integer(_ value: Any?) -> Int {
        switch value {
        case let value as Int: max(0, value)
        case let value as NSNumber: max(0, value.intValue)
        case let value as String: max(0, Int(value) ?? 0)
        default: 0
        }
    }
}

/// Formats token counts for chrome that must not reflow as the number grows.
enum AgentTokenUsageFormatter {
    /// `812`, `24.6K`, `1.28M`. Three significant figures at every magnitude so
    /// the column width stays put while the value climbs.
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000:
            return "\(tokens)"
        case ..<1_000_000:
            return "\(rounded(Double(tokens) / 1_000, decimals: tokens < 10_000 ? 1 : 0))K"
        default:
            return "\(rounded(Double(tokens) / 1_000_000, decimals: 2))M"
        }
    }

    private static func rounded(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
