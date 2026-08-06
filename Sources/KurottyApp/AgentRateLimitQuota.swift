import Foundation

/// How much of a plan's rate-limit window an agent has already spent, and when
/// that window rolls over.
///
/// This is a different question from `AgentTokenUsage` and from
/// `AgentContextForecast`. Token usage is what a session cost, context is how
/// full one conversation is; a quota window is how much of the *account's*
/// allowance is gone, and it is the only one of the three that resets on a
/// clock rather than on a compaction.
///
/// Provenance is the whole constraint here. Codex writes `rate_limits` beside
/// every `token_count` event in its rollout transcript, so this is read from
/// exactly the same bounded transcript read the session index already performs:
/// no credential, no network, no new file. Claude Code writes nothing of the
/// kind anywhere under `~/.claude`, so a Claude entry stays empty and the
/// surfaces above report it as unreported rather than inventing a number. See
/// `docs/architecture.md`, "Coding-agent integration".
struct AgentRateLimitWindow: Equatable, Sendable {
    /// Share of the window consumed, clamped into 0...1.
    ///
    /// Clamped, unlike `AgentContextForecast.usedFraction`, because the two
    /// numbers are not the same kind of claim: context occupancy legitimately
    /// exceeds its window before a compaction, whereas a provider reporting
    /// more than 100% of an allowance is a payload error, and rendering a meter
    /// past full would read as a Kurotty bug rather than as an agent one.
    let usedFraction: Double
    /// Length of the window the provider reported. Kept rather than folded into
    /// a `session`/`weekly` enum: the duration *is* the window's identity, so
    /// labelling it from its own minutes cannot misclassify a bucket Kurotty
    /// has never seen. Codex has already moved a plan from a 300-minute primary
    /// window to a 10080-minute one in the same `primary` slot, which is
    /// precisely what a positional or fixed-set classifier gets wrong.
    let windowMinutes: Int
    /// When the window rolls over, if the provider said. Nil is a real state:
    /// the percentage is still worth showing without it.
    let resetsAt: Date?

    /// True once the window the reading describes has already rolled over.
    ///
    /// This is the common case, not an edge case: the index holds every session
    /// on disk, and a transcript from last month carries a reset date from last
    /// month. A stale percentage is worse than no percentage, so callers drop
    /// expired windows instead of displaying them.
    func isExpired(now: Date) -> Bool {
        guard let resetsAt else {
            return false
        }
        return resetsAt <= now
    }

    /// Seconds until the rollover. Nil when unknown or already past.
    func secondsUntilReset(now: Date) -> TimeInterval? {
        guard let resetsAt else {
            return nil
        }
        let remaining = resetsAt.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }
}

/// Every rate-limit window one agent reported, as of one observation.
struct AgentRateLimitQuota: Equatable, Sendable {
    /// Ascending by window length, so the tightest window — the one that bites
    /// first — always leads.
    let windows: [AgentRateLimitWindow]
    /// Transcript timestamp of the record that carried these windows. Used to
    /// pick between sessions, because two Codex sessions both hold a reading
    /// and only the newer one describes the account now.
    let observedAt: Date

    /// Windows that have not rolled over yet.
    func currentWindows(now: Date) -> [AgentRateLimitWindow] {
        windows.filter { !$0.isExpired(now: now) }
    }
}

/// Reads rate-limit windows out of a transcript record.
///
/// Every field is treated as untrusted: the rollout schema is not a contract,
/// and a bounded head/tail read can hand this a record from a Codex version
/// that predates or postdates the shape below. Anything unreadable yields nil
/// for that window rather than a zero.
enum AgentRateLimitQuotaParsing {
    private enum Field {
        static let rateLimits = "rate_limits"
        /// Codex names the slots positionally. They are read as an unordered
        /// set: which slot holds which duration has already changed once.
        static let slots = ["primary", "secondary"]
        static let usedPercent = "used_percent"
        static let windowMinutes = "window_minutes"
        static let resetsAt = "resets_at"
    }

    private enum Scale {
        static let percentPerUNIT = 100.0
        /// Splits a seconds epoch from a milliseconds one: 1e10 seconds lands in
        /// 2286 and 1e10 milliseconds in 1970, so no plausible reading of either
        /// unit falls on the wrong side.
        static let millisecondEpochFLOOR = 10_000_000_000.0
        static let millisecondsPerSecondRATIO = 1_000.0
    }

    /// Windows from a Codex `token_count` event payload, ascending by length.
    ///
    /// Nil when the payload carries no readable window at all, so a caller can
    /// tell "this record said nothing" from "this record said zero percent".
    static func codexWindows(in payload: [String: Any]) -> [AgentRateLimitWindow]? {
        guard let rateLimits = payload[Field.rateLimits] as? [String: Any] else {
            return nil
        }
        let windows = Field.slots
            .compactMap { rateLimits[$0] as? [String: Any] }
            .compactMap(window(in:))
            .sorted { $0.windowMinutes < $1.windowMinutes }
        return windows.isEmpty ? nil : windows
    }

    private static func window(in slot: [String: Any]) -> AgentRateLimitWindow? {
        guard let percent = finiteDouble(slot[Field.usedPercent]),
              let minutes = positiveInteger(slot[Field.windowMinutes])
        else {
            return nil
        }
        return AgentRateLimitWindow(
            usedFraction: min(1, max(0, percent / Scale.percentPerUNIT)),
            windowMinutes: minutes,
            resetsAt: resetDate(from: slot[Field.resetsAt])
        )
    }

    /// Epoch seconds today. A millisecond epoch and an ISO-8601 string are both
    /// accepted so a schema rename degrades to a parseable timestamp instead of
    /// silently dropping every reset date.
    static func resetDate(from value: Any?) -> Date? {
        if let number = finiteDouble(value) {
            return date(fromEpoch: number)
        }
        guard let text = AgentSessionTranscriptParsing.nonEmptyString(value) else {
            return nil
        }
        if let number = Double(text) {
            return date(fromEpoch: number)
        }
        return AgentSessionTimestampParser().date(from: text)
    }

    private static func date(fromEpoch value: Double) -> Date? {
        guard value > 0 else {
            return nil
        }
        let seconds = value > Scale.millisecondEpochFLOOR
            ? value / Scale.millisecondsPerSecondRATIO
            : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let value as Double: number = value
        case let value as Int: number = Double(value)
        case let value as NSNumber: number = value.doubleValue
        default: number = nil
        }
        guard let number, number.isFinite else {
            return nil
        }
        return number
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = finiteDouble(value), number >= 1 else {
            return nil
        }
        return Int(number)
    }
}

/// Accumulates quota readings while a transcript is scanned once, top to
/// bottom.
///
/// Mirrors `AgentContextForecastBuilder`: a quota is a level rather than an
/// increment, so a later reading replaces an earlier one instead of adding to
/// it. Summing them would be meaningless — each event restates the same
/// account-wide allowance.
struct AgentRateLimitQuotaBuilder {
    private var windows: [AgentRateLimitWindow]?
    private var observedAt: Date?

    /// - Parameter timestamp: the transcript timestamp of the record that
    ///   carried the reading, used to rank this session against other sessions.
    mutating func observe(windows: [AgentRateLimitWindow], timestamp: Date?) {
        guard !windows.isEmpty else {
            return
        }
        self.windows = windows
        observedAt = timestamp ?? observedAt
    }

    /// - Parameter fallbackObservedAt: used when the carrying record had no
    ///   parseable timestamp; the caller passes the session's own latest
    ///   timestamp, which is the closest true statement available.
    func quota(fallbackObservedAt: Date) -> AgentRateLimitQuota? {
        guard let windows else {
            return nil
        }
        return AgentRateLimitQuota(windows: windows, observedAt: observedAt ?? fallbackObservedAt)
    }
}

/// Per-agent quota rolled up across every indexed session.
///
/// One entry per agent that has any indexed session, whether or not that agent
/// reports quota, because a Claude row reading "not reported" answers the
/// question the user actually has. Silently omitting Claude would leave them
/// wondering whether Kurotty forgot or the limit is fine.
struct AgentRateLimitQuotaSummary: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let agent: AgentSessionKind
        /// Windows still in force. Empty means unknown: either the agent writes
        /// no quota to disk, or every reading Kurotty holds has already reset.
        let windows: [AgentRateLimitWindow]
        /// When the newest surviving reading was taken. Nil alongside empty
        /// `windows`.
        let observedAt: Date?

        var isReported: Bool {
            !windows.isEmpty
        }
    }

    let entries: [Entry]

    static let empty = AgentRateLimitQuotaSummary(entries: [])

    var isEmpty: Bool {
        entries.isEmpty
    }

    /// True when at least one agent actually reported a live window. The
    /// surfaces hide themselves entirely on false rather than showing a panel
    /// of dashes.
    var hasAnyReportedWindow: Bool {
        entries.contains { $0.isReported }
    }

    /// The fullest window across every agent — the one that will stop work
    /// first, and therefore the single number the status bar condenses to.
    var tightestWindow: (agent: AgentSessionKind, window: AgentRateLimitWindow)? {
        entries
            .flatMap { entry in entry.windows.map { (entry.agent, $0) } }
            .max { $0.1.usedFraction < $1.1.usedFraction }
    }

    /// - Parameters:
    ///   - records: every indexed session; the newest reading per agent wins.
    ///   - now: evaluation instant, so an already-rolled-over window is dropped.
    static func make(records: [AgentSessionRecord], now: Date) -> AgentRateLimitQuotaSummary {
        var agentsSeen: Set<AgentSessionKind> = []
        var newestQuotaByAgent: [AgentSessionKind: AgentRateLimitQuota] = [:]
        for record in records {
            agentsSeen.insert(record.agent)
            guard let quota = record.rateLimitQuota else {
                continue
            }
            guard let existing = newestQuotaByAgent[record.agent] else {
                newestQuotaByAgent[record.agent] = quota
                continue
            }
            if quota.observedAt > existing.observedAt {
                newestQuotaByAgent[record.agent] = quota
            }
        }

        // Ordered by the enum rather than by recency: a section whose rows
        // reorder themselves on every index refresh is unreadable.
        let entries = AgentSessionKind.allCases
            .filter(agentsSeen.contains)
            .map { agent -> Entry in
                let quota = newestQuotaByAgent[agent]
                let windows = quota?.currentWindows(now: now) ?? []
                return Entry(
                    agent: agent,
                    windows: windows,
                    observedAt: windows.isEmpty ? nil : quota?.observedAt
                )
            }
        return AgentRateLimitQuotaSummary(entries: entries)
    }
}

/// Wording and severity for the quota surfaces, kept out of the views so both
/// the sidebar section and the status bar read from one table.
enum AgentRateLimitQuotaCopy {
    /// How close a window is to stopping work.
    enum Pressure: Equatable, Sendable {
        case comfortable
        case warning
        case exhausted
    }

    private enum Threshold {
        /// Same rungs as `AgentContextForecast`: both answer "how full is a
        /// window", so a user who has learned what an amber meter means in one
        /// place must not have to relearn it in the other.
        static let warningRATIO = 0.8
        static let exhaustedRATIO = 1.0
    }

    private enum Duration {
        static let minutesPerHOUR = 60
        static let minutesPerDAY = 1_440
        static let secondsPerMINUTE = 60.0
    }

    private enum Format {
        static let separator = " · "
        /// Units stay untranslated, matching the relative ages the command
        /// history and session rows already render as "3m" / "2h" / "5d".
        static let dayUnit = "d"
        static let hourUnit = "h"
        static let minuteUnit = "m"
    }

    static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    static func pressure(forFraction fraction: Double) -> Pressure {
        if fraction >= Threshold.exhaustedRATIO {
            return .exhausted
        }
        return fraction >= Threshold.warningRATIO ? .warning : .comfortable
    }

    /// A window named by its own length: `5h`, `7d`, `45m`. The label is
    /// derived rather than looked up so a duration Kurotty has never seen still
    /// gets an exact name instead of falling into an "other" bucket.
    static func windowLabel(minutes: Int) -> String {
        guard minutes > 0 else {
            return "0\(Format.minuteUnit)"
        }
        if minutes.isMultiple(of: Duration.minutesPerDAY) {
            return "\(minutes / Duration.minutesPerDAY)\(Format.dayUnit)"
        }
        if minutes.isMultiple(of: Duration.minutesPerHOUR) {
            return "\(minutes / Duration.minutesPerHOUR)\(Format.hourUnit)"
        }
        return "\(minutes)\(Format.minuteUnit)"
    }

    /// `1d 10h`, `4h 12m`, `9m`. Two units at most: the second one is already
    /// below the precision anybody plans around.
    static func compactDuration(seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / Duration.secondsPerMINUTE).rounded(.down)))
        let days = totalMinutes / Duration.minutesPerDAY
        let hours = (totalMinutes % Duration.minutesPerDAY) / Duration.minutesPerHOUR
        let minutes = totalMinutes % Duration.minutesPerHOUR
        if days > 0 {
            return "\(days)\(Format.dayUnit) \(hours)\(Format.hourUnit)"
        }
        if hours > 0 {
            return "\(hours)\(Format.hourUnit) \(minutes)\(Format.minuteUnit)"
        }
        return "\(minutes)\(Format.minuteUnit)"
    }

    /// `Resets in 1d 10h`. Nil when the provider gave no reset date, or when it
    /// has already passed — the caller should have dropped that window.
    static func resetLabel(
        for window: AgentRateLimitWindow,
        now: Date,
        language: AppLanguage = AppLocalization.language
    ) -> String? {
        guard let remaining = window.secondsUntilReset(now: now) else {
            return nil
        }
        return AppLocalization.format(
            .agentQuotaResetsIn,
            language: language,
            compactDuration(seconds: remaining)
        )
    }

    /// One window as a single line: `Codex 5h · 32% · Resets in 4h 12m`.
    static func rowSummary(
        agent: AgentSessionKind,
        window: AgentRateLimitWindow,
        now: Date,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        var parts = [
            "\(agent.shortLabel) \(windowLabel(minutes: window.windowMinutes))",
            "\(percent(window.usedFraction))%",
        ]
        if let reset = resetLabel(for: window, now: now, language: language) {
            parts.append(reset)
        }
        return parts.joined(separator: Format.separator)
    }

    /// Tooltip for an agent that reports nothing, naming the agent so the row
    /// reads as a fact about that product rather than as a Kurotty failure.
    static func notReportedSummary(
        agent: AgentSessionKind,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        AppLocalization.format(.agentQuotaNotReported, language: language, agent.displayName)
    }

    /// Whole-summary tooltip: every live window, one per line, with a trailing
    /// line for each agent that reports none.
    static func summaryTooltip(
        for summary: AgentRateLimitQuotaSummary,
        now: Date,
        language: AppLanguage = AppLocalization.language
    ) -> String? {
        guard !summary.isEmpty else {
            return nil
        }
        let lines = summary.entries.flatMap { entry -> [String] in
            guard entry.isReported else {
                return [notReportedSummary(agent: entry.agent, language: language)]
            }
            return entry.windows.map {
                rowSummary(agent: entry.agent, window: $0, now: now, language: language)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func accessibilityLabel(
        agent: AgentSessionKind,
        window: AgentRateLimitWindow,
        language: AppLanguage = AppLocalization.language
    ) -> String {
        AppLocalization.format(
            .agentQuotaAccessibility,
            language: language,
            agent.shortLabel,
            windowLabel(minutes: window.windowMinutes),
            percent(window.usedFraction)
        )
    }
}
