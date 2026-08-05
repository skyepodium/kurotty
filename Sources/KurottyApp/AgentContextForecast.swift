import Foundation

/// Context windows for the models Kurotty can name, keyed by model id.
///
/// This table exists only because Claude transcripts do not record a context
/// window anywhere. Codex writes `model_context_window` beside every
/// `token_count` event, so Codex sessions never consult this.
///
/// A model that is not listed returns nil, and every surface above reports the
/// limit as unknown rather than substituting a plausible number. That is the
/// whole contract: a wrong limit produces a wrong "how much room is left",
/// which is worse than no answer, so entries are only added for models whose
/// published window is known.
enum AgentModelContextWindow {
    private enum Window {
        static let oneMillionTOKENS = 1_000_000
        static let twoHundredThousandTOKENS = 200_000
    }

    /// Matched against the model id exactly, or against `id-<date>` so dated
    /// snapshots such as `claude-haiku-4-5-20251001` resolve to their family.
    private static let windowsByModelID: [String: Int] = [
        "claude-opus-5": Window.oneMillionTOKENS,
        "claude-opus-4-8": Window.oneMillionTOKENS,
        "claude-opus-4-7": Window.oneMillionTOKENS,
        "claude-opus-4-6": Window.oneMillionTOKENS,
        "claude-sonnet-5": Window.oneMillionTOKENS,
        "claude-sonnet-4-6": Window.oneMillionTOKENS,
        "claude-fable-5": Window.oneMillionTOKENS,
        "claude-mythos-5": Window.oneMillionTOKENS,
        "claude-haiku-4-5": Window.twoHundredThousandTOKENS,
    ]

    /// Nil for an unknown, absent, or synthetic model. Callers must treat nil
    /// as "unknown" and must not fall back to a default window.
    static func tokens(forModel model: String?) -> Int? {
        guard let model = AgentSessionTranscriptParsing.nonEmptyString(model) else {
            return nil
        }
        if let exact = windowsByModelID[model] {
            return exact
        }
        // A dated snapshot keeps its family's window. Matching on `id-` rather
        // than a bare prefix stops `claude-sonnet-4-5` from resolving through
        // an unrelated shorter entry.
        for (id, tokens) in windowsByModelID where model.hasPrefix(id + "-") {
            return tokens
        }
        return nil
    }
}

/// How much of a session's context window is consumed, and roughly how much
/// room is left.
///
/// Two of these three numbers are read off disk and one is inferred, and the
/// type keeps them separable on purpose:
///
/// - `usedTokens` is measured. It is the occupancy recorded for the most recent
///   model request, not a sum over the session: re-sending the conversation
///   every turn means the cumulative token count passes the context window long
///   before the window is actually full.
/// - `limit` is measured for Codex and derived from the model name for Claude,
///   and `LimitSource` says which. It is nil when neither is available.
/// - `tokensPerTurn` and everything built on it (`remainingTurns`) are
///   estimates from observed growth, and are nil when growth was never seen.
struct AgentContextForecast: Equatable, Sendable {
    /// Where the context window came from. Kept because a transcript-recorded
    /// window is a fact and a table lookup is a claim about a model id.
    enum LimitSource: Equatable, Sendable {
        /// The agent wrote the window into the transcript.
        case transcript
        /// Resolved from the model name through `AgentModelContextWindow`.
        case modelTable
    }

    struct Limit: Equatable, Sendable {
        let tokens: Int
        let source: LimitSource
    }

    /// How full the window is. Nil whenever `limit` is nil, because without a
    /// window there is no such thing as pressure.
    enum Pressure: Equatable, Sendable {
        case comfortable
        case warning
        case exhausted
    }

    private enum Threshold {
        /// Where the meter stops being recessive. Chosen to leave room to react:
        /// on the real sessions measured for this change, per-request growth was
        /// under 1% of the window, so a fifth of the window remaining is still
        /// tens of turns.
        static let warningRATIO = 0.8
        static let exhaustedRATIO = 1.0
    }

    private enum Growth {
        /// Fewest growth steps that will be turned into a rate.
        ///
        /// A bounded head/tail read contributes exactly one bogus step, where
        /// the head window's last request is followed by the tail window's
        /// first. One outlier shifts a median by at most one rank, so five
        /// steps is the point where it can no longer reach the middle. Below
        /// that the rate is not reported at all: measured on real transcripts,
        /// a two-sample session estimated 162,948 tokens per turn against a
        /// true rate near 1,000.
        static let minimumStepCOUNT = 5
    }

    /// Occupancy of the most recent model request: its prompt plus its reply.
    let usedTokens: Int
    let limit: Limit?
    /// Median growth in occupancy per model request, over the requests observed.
    ///
    /// Median rather than mean, for two reasons that both show up in real
    /// transcripts. Large transcripts are only read as a head window plus a tail
    /// window, so one delta spans the gap between them and is enormous; and a
    /// session that compacted has negative steps. A median absorbs both, a mean
    /// does not.
    let tokensPerTurn: Int?
    /// How many model requests contributed. Exposed so a caller can tell a
    /// one-sample session from a well-observed one.
    let sampleCount: Int

    static let unknown = AgentContextForecast(
        usedTokens: 0,
        limit: nil,
        tokensPerTurn: nil,
        sampleCount: 0
    )

    /// True when the transcript carried no token accounting at all.
    var isEmpty: Bool {
        sampleCount == 0
    }

    /// Fraction of the window in use. Not clamped: a session that ran past its
    /// window before compacting reports more than 1, and hiding that would be
    /// the same kind of lie as inventing a limit.
    var usedFraction: Double? {
        guard let limit, limit.tokens > 0 else {
            return nil
        }
        return Double(usedTokens) / Double(limit.tokens)
    }

    var remainingTokens: Int? {
        guard let limit else {
            return nil
        }
        return max(0, limit.tokens - usedTokens)
    }

    /// Roughly how many more model requests fit before the window is full.
    ///
    /// A "turn" here is one model request — one assistant message for Claude,
    /// one `token_count` event for Codex — not one thing the user typed. A
    /// single prompt that runs a dozen tools spends a dozen of these.
    ///
    /// Nil when the window or the growth rate is unknown. Zero once the window
    /// is full.
    var remainingTurns: Int? {
        guard let remainingTokens, let tokensPerTurn, tokensPerTurn > 0 else {
            return nil
        }
        return remainingTokens / tokensPerTurn
    }

    var pressure: Pressure? {
        guard let usedFraction else {
            return nil
        }
        if usedFraction >= Threshold.exhaustedRATIO {
            return .exhausted
        }
        return usedFraction >= Threshold.warningRATIO ? .warning : .comfortable
    }

    /// - Parameters:
    ///   - samples: occupancy of each model request, oldest first.
    ///   - limit: the window, when one is known.
    static func make(samples: [Int], limit: Limit?) -> AgentContextForecast {
        guard let used = samples.last else {
            return AgentContextForecast(
                usedTokens: 0,
                limit: limit,
                tokensPerTurn: nil,
                sampleCount: 0
            )
        }
        return AgentContextForecast(
            usedTokens: max(0, used),
            limit: limit,
            tokensPerTurn: medianGrowth(in: samples),
            sampleCount: samples.count
        )
    }

    /// Median of the steps where occupancy grew. Steps that shrank are dropped
    /// rather than averaged in: they are compaction or a read-window seam, not
    /// a rate at which the window fills.
    private static func medianGrowth(in samples: [Int]) -> Int? {
        let growth = zip(samples, samples.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0 }
            .sorted()
        guard growth.count >= Growth.minimumStepCOUNT else {
            return nil
        }
        let middle = growth.count / 2
        guard growth.count.isMultiple(of: 2) else {
            return growth[middle]
        }
        return (growth[middle - 1] + growth[middle]) / 2
    }
}

/// Wording for the context meter, kept out of the view so it stays testable
/// without AppKit and so the measured half of the sentence stays separable from
/// the estimated half.
enum AgentContextForecastCopy {
    private enum Format {
        static let separator = " · "
    }

    /// Percentage of the window in use, rounded for display. The underlying
    /// fraction is not rounded.
    static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// One tooltip line. Nil when the transcript recorded no token accounting,
    /// so the row says nothing rather than saying zero.
    ///
    /// The occupancy and the window are stated plainly; the turn estimate is
    /// marked with a tilde and omitted entirely when growth was never measured.
    static func summary(for forecast: AgentContextForecast) -> String? {
        guard !forecast.isEmpty else {
            return nil
        }
        let label = AppLocalization.string(.agentContextLabel)
        guard let fraction = forecast.usedFraction, let limit = forecast.limit else {
            let used = AgentTokenUsageFormatter.compact(forecast.usedTokens)
            return label + " " + AppLocalization.format(.agentContextLimitUnknown, used)
        }
        var parts = [
            label + " " + AppLocalization.format(
                .agentContextOfLimit,
                percent(fraction),
                AgentTokenUsageFormatter.compact(limit.tokens)
            ),
        ]
        if forecast.pressure == .exhausted {
            parts.append(AppLocalization.string(.agentContextOverLimit))
        } else if let turns = forecast.remainingTurns {
            parts.append(AppLocalization.format(.agentContextTurnsLeft, turns))
        }
        return parts.joined(separator: Format.separator)
    }

    /// Screen-reader label for the meter. Nil whenever the meter is not shown.
    static func accessibilityLabel(for forecast: AgentContextForecast) -> String? {
        guard let fraction = forecast.usedFraction else {
            return nil
        }
        return AppLocalization.format(.agentContextAccessibility, percent(fraction))
    }
}

/// Accumulates the occupancy samples and window that a forecast is built from
/// while a transcript is scanned once, top to bottom.
///
/// Split out so both scanners share one accumulation rule instead of each
/// growing their own, and so the rule stays testable without a transcript.
struct AgentContextForecastBuilder {
    private var samples: [Int] = []
    private var transcriptWindowTokens: Int?

    /// One model request's occupancy: its prompt plus its reply.
    mutating func observe(occupancyTokens: Int) {
        guard occupancyTokens > 0 else {
            return
        }
        samples.append(occupancyTokens)
    }

    /// A context window the agent itself recorded. Later events supersede
    /// earlier ones so a session that switched models reports the window it
    /// ended on.
    mutating func observe(transcriptContextWindow tokens: Int) {
        guard tokens > 0 else {
            return
        }
        transcriptWindowTokens = tokens
    }

    /// - Parameter model: the last model seen, consulted only when the
    ///   transcript recorded no window of its own.
    func forecast(model: String?) -> AgentContextForecast {
        AgentContextForecast.make(samples: samples, limit: limit(model: model))
    }

    private func limit(model: String?) -> AgentContextForecast.Limit? {
        if let transcriptWindowTokens {
            return AgentContextForecast.Limit(tokens: transcriptWindowTokens, source: .transcript)
        }
        guard let tokens = AgentModelContextWindow.tokens(forModel: model) else {
            return nil
        }
        return AgentContextForecast.Limit(tokens: tokens, source: .modelTable)
    }
}
