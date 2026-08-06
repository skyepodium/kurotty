import AppKit
import Foundation
import XCTest
@testable import KurottyApp

/// Rate-limit quota is the one agent number Kurotty reads that describes the
/// *account* rather than the session, and the only source it accepts is what
/// the agent already wrote to disk. Codex records it beside every `token_count`
/// event; Claude Code records it nowhere. These tests pin both halves of that,
/// plus the arithmetic that decides when a reading has gone stale.
final class AgentRateLimitQuotaParsingTests: XCTestCase {
    /// The exact shape a current Codex rollout writes.
    private func payload(
        primary: [String: Any]? = nil,
        secondary: Any? = nil
    ) -> [String: Any] {
        var rateLimits: [String: Any] = ["limit_id": "codex", "plan_type": "prolite"]
        if let primary {
            rateLimits["primary"] = primary
        }
        if let secondary {
            rateLimits["secondary"] = secondary
        }
        return ["type": "token_count", "info": [:], "rate_limits": rateLimits]
    }

    func testReadsBothWindowsFromARealCodexPayload() throws {
        let windows = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 32.0, "window_minutes": 300, "resets_at": 1_781_961_059],
            secondary: ["used_percent": 8.5, "window_minutes": 10_080, "resets_at": 1_782_547_859]
        )))

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].windowMinutes, 300)
        XCTAssertEqual(windows[0].usedFraction, 0.32, accuracy: 0.0001)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_781_961_059))
        XCTAssertEqual(windows[1].windowMinutes, 10_080)
        XCTAssertEqual(windows[1].usedFraction, 0.085, accuracy: 0.0001)
    }

    /// Codex has already shipped a plan whose only window is the weekly one and
    /// puts it in `primary`. A positional reader would label that "session"; the
    /// duration is the identity, so it is read straight off `window_minutes`.
    func testAWeeklyWindowInThePrimarySlotStaysAWeeklyWindow() throws {
        let windows = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 32.0, "window_minutes": 10_080, "resets_at": 1_786_183_055],
            secondary: NSNull()
        )))

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].windowMinutes, 10_080)
        XCTAssertEqual(AgentRateLimitQuotaCopy.windowLabel(minutes: windows[0].windowMinutes), "7d")
    }

    func testWindowsAreOrderedTightestFirstRegardlessOfSlotOrder() throws {
        let windows = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 1.0, "window_minutes": 10_080],
            secondary: ["used_percent": 2.0, "window_minutes": 300]
        )))

        XCTAssertEqual(windows.map(\.windowMinutes), [300, 10_080])
    }

    func testAPayloadWithoutRateLimitsReportsNothingRatherThanZero() {
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: ["type": "token_count", "info": [:]]))
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: payload()))
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: ["rate_limits": "not an object"]))
    }

    /// A bounded head/tail read can hand the parser a record from any Codex
    /// version. Every malformed field drops its own window instead of
    /// contributing a zero that would render as "0% used".
    func testMalformedFieldsDropTheirWindow() {
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": "thirty", "window_minutes": 300]
        )))
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 32.0]
        )))
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 32.0, "window_minutes": 0]
        )))
        XCTAssertNil(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": Double.nan, "window_minutes": 300]
        )))
    }

    func testOneMalformedWindowDoesNotDiscardTheOtherOne() throws {
        let windows = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 44.0, "window_minutes": 300],
            secondary: ["window_minutes": 10_080]
        )))

        XCTAssertEqual(windows.map(\.windowMinutes), [300])
    }

    /// A provider reporting more or less than the whole allowance is a payload
    /// error, not a state worth rendering; the meter clamps rather than
    /// overflowing its own track.
    func testOutOfRangePercentagesClampIntoTheTrack() throws {
        let over = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 137.0, "window_minutes": 300]
        )))
        let under = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": -4.0, "window_minutes": 300]
        )))

        XCTAssertEqual(over[0].usedFraction, 1)
        XCTAssertEqual(under[0].usedFraction, 0)
    }

    func testAWindowWithoutAResetDateStillReportsItsPercentage() throws {
        let windows = try XCTUnwrap(AgentRateLimitQuotaParsing.codexWindows(in: payload(
            primary: ["used_percent": 61.0, "window_minutes": 300]
        )))

        XCTAssertNil(windows[0].resetsAt)
        XCTAssertEqual(AgentRateLimitQuotaCopy.percent(windows[0].usedFraction), 61)
    }

    /// Epoch seconds today. A millisecond epoch or an ISO string is accepted so
    /// a schema rename degrades to a parseable date rather than going dark.
    func testResetTimestampsAreReadInEverySpellingSeenOrPlausible() {
        let expected = Date(timeIntervalSince1970: 1_781_961_059)
        XCTAssertEqual(AgentRateLimitQuotaParsing.resetDate(from: 1_781_961_059), expected)
        XCTAssertEqual(AgentRateLimitQuotaParsing.resetDate(from: 1_781_961_059_000), expected)
        XCTAssertEqual(AgentRateLimitQuotaParsing.resetDate(from: "1781961059"), expected)
        XCTAssertEqual(AgentRateLimitQuotaParsing.resetDate(from: "2026-06-20T13:10:59Z"), expected)
    }

    func testUnreadableResetTimestampsYieldNoDate() {
        XCTAssertNil(AgentRateLimitQuotaParsing.resetDate(from: nil))
        XCTAssertNil(AgentRateLimitQuotaParsing.resetDate(from: "soon"))
        XCTAssertNil(AgentRateLimitQuotaParsing.resetDate(from: 0))
        XCTAssertNil(AgentRateLimitQuotaParsing.resetDate(from: -5))
    }
}

/// Every reading restates the same account-wide allowance, so a later one
/// replaces an earlier one; summing would multiply the number by the event
/// count, which is the same trap `AgentTokenUsageParsing` documents for Codex.
final class AgentRateLimitQuotaBuilderTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func window(_ percent: Double, minutes: Int = 300) -> AgentRateLimitWindow {
        AgentRateLimitWindow(usedFraction: percent / 100, windowMinutes: minutes, resetsAt: nil)
    }

    func testALaterReadingSupersedesAnEarlierOne() throws {
        var builder = AgentRateLimitQuotaBuilder()
        builder.observe(windows: [window(10)], timestamp: epoch)
        builder.observe(windows: [window(41)], timestamp: epoch.addingTimeInterval(60))

        let quota = try XCTUnwrap(builder.quota(fallbackObservedAt: epoch))
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(AgentRateLimitQuotaCopy.percent(quota.windows[0].usedFraction), 41)
        XCTAssertEqual(quota.observedAt, epoch.addingTimeInterval(60))
    }

    func testATranscriptThatNeverReportedQuotaYieldsNone() {
        var builder = AgentRateLimitQuotaBuilder()
        builder.observe(windows: [], timestamp: epoch)

        XCTAssertNil(builder.quota(fallbackObservedAt: epoch))
    }

    /// A record with no parseable timestamp still carries a usable reading; it
    /// falls back to the session's own latest timestamp, which is the closest
    /// true statement available for ranking it against other sessions.
    func testAReadingWithoutATimestampFallsBackToTheSessionTime() throws {
        var builder = AgentRateLimitQuotaBuilder()
        builder.observe(windows: [window(7)], timestamp: nil)

        XCTAssertEqual(try XCTUnwrap(builder.quota(fallbackObservedAt: epoch)).observedAt, epoch)
    }
}

final class AgentRateLimitWindowArithmeticTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func window(resetsAt: Date?) -> AgentRateLimitWindow {
        AgentRateLimitWindow(usedFraction: 0.5, windowMinutes: 300, resetsAt: resetsAt)
    }

    /// The common case, not an edge case: the index holds every transcript on
    /// disk, so most readings describe a window that rolled over weeks ago.
    func testAResetAlreadyInThePastMarksTheWindowExpired() {
        XCTAssertTrue(window(resetsAt: now.addingTimeInterval(-1)).isExpired(now: now))
        XCTAssertTrue(window(resetsAt: now).isExpired(now: now))
        XCTAssertFalse(window(resetsAt: now.addingTimeInterval(1)).isExpired(now: now))
    }

    func testAWindowWithoutAResetDateNeverExpires() {
        XCTAssertFalse(window(resetsAt: nil).isExpired(now: now))
        XCTAssertNil(window(resetsAt: nil).secondsUntilReset(now: now))
    }

    func testSecondsUntilResetIsNilOncePast() {
        XCTAssertNil(window(resetsAt: now.addingTimeInterval(-60)).secondsUntilReset(now: now))
        XCTAssertEqual(window(resetsAt: now.addingTimeInterval(90)).secondsUntilReset(now: now), 90)
    }

    func testExpiredWindowsAreDroppedFromAQuota() {
        let quota = AgentRateLimitQuota(
            windows: [
                window(resetsAt: now.addingTimeInterval(-3_600)),
                window(resetsAt: now.addingTimeInterval(3_600)),
            ],
            observedAt: now
        )

        XCTAssertEqual(quota.currentWindows(now: now).count, 1)
        XCTAssertEqual(
            quota.currentWindows(now: now)[0].resetsAt,
            now.addingTimeInterval(3_600)
        )
    }
}

final class AgentRateLimitQuotaCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testWindowsAreNamedByTheirOwnDuration() {
        XCTAssertEqual(AgentRateLimitQuotaCopy.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(AgentRateLimitQuotaCopy.windowLabel(minutes: 10_080), "7d")
        // A bucket Kurotty has never seen still gets an exact name.
        XCTAssertEqual(AgentRateLimitQuotaCopy.windowLabel(minutes: 45), "45m")
        XCTAssertEqual(AgentRateLimitQuotaCopy.windowLabel(minutes: 43_200), "30d")
    }

    func testDurationsRenderAtMostTwoUnits() {
        XCTAssertEqual(AgentRateLimitQuotaCopy.compactDuration(seconds: 122_400), "1d 10h")
        XCTAssertEqual(AgentRateLimitQuotaCopy.compactDuration(seconds: 15_120), "4h 12m")
        XCTAssertEqual(AgentRateLimitQuotaCopy.compactDuration(seconds: 540), "9m")
        XCTAssertEqual(AgentRateLimitQuotaCopy.compactDuration(seconds: 10), "0m")
        XCTAssertEqual(AgentRateLimitQuotaCopy.compactDuration(seconds: -10), "0m")
    }

    func testResetLabelIsAbsentWithoutAFutureReset() {
        let noDate = AgentRateLimitWindow(usedFraction: 0.5, windowMinutes: 300, resetsAt: nil)
        let past = AgentRateLimitWindow(
            usedFraction: 0.5,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(-60)
        )
        let future = AgentRateLimitWindow(
            usedFraction: 0.5,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(122_400)
        )

        XCTAssertNil(AgentRateLimitQuotaCopy.resetLabel(for: noDate, now: now, language: .english))
        XCTAssertNil(AgentRateLimitQuotaCopy.resetLabel(for: past, now: now, language: .english))
        XCTAssertEqual(
            AgentRateLimitQuotaCopy.resetLabel(for: future, now: now, language: .english),
            "Resets in 1d 10h"
        )
    }

    /// The same rungs as the context meter: a user who has learned what amber
    /// means in one place must not have to relearn it in the other.
    func testPressureRungsMatchTheContextMeter() {
        XCTAssertEqual(AgentRateLimitQuotaCopy.pressure(forFraction: 0), .comfortable)
        XCTAssertEqual(AgentRateLimitQuotaCopy.pressure(forFraction: 0.79), .comfortable)
        XCTAssertEqual(AgentRateLimitQuotaCopy.pressure(forFraction: 0.8), .warning)
        XCTAssertEqual(AgentRateLimitQuotaCopy.pressure(forFraction: 0.99), .warning)
        XCTAssertEqual(AgentRateLimitQuotaCopy.pressure(forFraction: 1), .exhausted)
    }

    func testRowSummaryNamesTheAgentTheWindowAndTheReset() {
        let window = AgentRateLimitWindow(
            usedFraction: 0.32,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(15_120)
        )

        XCTAssertEqual(
            AgentRateLimitQuotaCopy.rowSummary(
                agent: .codex,
                window: window,
                now: now,
                language: .english
            ),
            "Codex 5h · 32% · Resets in 4h 12m"
        )
    }

    /// The tooltip is the only place that says why an agent is missing, and it
    /// says it as a fact about the product rather than as a Kurotty failure.
    func testTheNotReportedLineNamesTheAgent() {
        let text = AgentRateLimitQuotaCopy.notReportedSummary(agent: .claudeCode, language: .english)

        XCTAssertEqual(text, "Claude Code does not record rate limits on disk")
    }

    func testEveryQuotaStringIsTranslatedInAllThreeLanguages() {
        let keys: [L10nKey] = [
            .agentQuotaTitle,
            .agentQuotaResetsIn,
            .agentQuotaNotReported,
            .agentQuotaAccessibility,
            .statusBarQuotaTitle,
        ]
        for key in keys {
            for language in AppLanguage.allCases {
                XCTAssertTrue(
                    AppLocalization.hasTranslation(for: key, language: language),
                    "\(key) is missing a \(language) translation"
                )
            }
        }
    }
}

/// The rollup the sidebar and the status bar both read from.
final class AgentRateLimitQuotaSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func record(
        agent: AgentSessionKind,
        sessionID: String,
        quota: AgentRateLimitQuota?
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            agent: agent,
            sessionID: sessionID,
            title: sessionID,
            cwd: "/tmp",
            updatedAt: now,
            createdAt: now,
            messageCount: 1,
            filePath: "/tmp/\(sessionID).jsonl",
            rateLimitQuota: quota
        )
    }

    private func quota(
        percent: Double,
        observedAt: Date,
        resetsIn: TimeInterval? = 3_600
    ) -> AgentRateLimitQuota {
        AgentRateLimitQuota(
            windows: [
                AgentRateLimitWindow(
                    usedFraction: percent / 100,
                    windowMinutes: 300,
                    resetsAt: resetsIn.map { observedAt.addingTimeInterval($0) }
                ),
            ],
            observedAt: observedAt
        )
    }

    func testTheNewestReadingPerAgentWins() throws {
        let summary = AgentRateLimitQuotaSummary.make(
            records: [
                record(agent: .codex, sessionID: "old", quota: quota(percent: 12, observedAt: now)),
                record(
                    agent: .codex,
                    sessionID: "new",
                    quota: quota(percent: 57, observedAt: now.addingTimeInterval(600))
                ),
            ],
            now: now
        )

        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.agent, .codex)
        XCTAssertEqual(AgentRateLimitQuotaCopy.percent(entry.windows[0].usedFraction), 57)
    }

    /// A Claude session produces a row so the absence is legible, but the row
    /// carries no windows and never invents a number.
    func testAnAgentThatReportsNothingStillGetsAnEntry() throws {
        let summary = AgentRateLimitQuotaSummary.make(
            records: [record(agent: .claudeCode, sessionID: "a", quota: nil)],
            now: now
        )

        let entry = try XCTUnwrap(summary.entries.first)
        XCTAssertEqual(entry.agent, .claudeCode)
        XCTAssertFalse(entry.isReported)
        XCTAssertTrue(entry.windows.isEmpty)
        XCTAssertNil(entry.observedAt)
        XCTAssertFalse(summary.hasAnyReportedWindow)
    }

    func testAgentsWithNoIndexedSessionAreAbsentEntirely() {
        let summary = AgentRateLimitQuotaSummary.make(
            records: [record(agent: .codex, sessionID: "a", quota: quota(percent: 4, observedAt: now))],
            now: now
        )

        XCTAssertEqual(summary.entries.map(\.agent), [.codex])
    }

    /// A stale percentage is worse than no percentage: the window it describes
    /// no longer exists.
    func testAnAlreadyResetReadingRendersAsUnknownRatherThanStale() {
        let stale = quota(percent: 96, observedAt: now.addingTimeInterval(-86_400), resetsIn: 60)
        let summary = AgentRateLimitQuotaSummary.make(
            records: [record(agent: .codex, sessionID: "a", quota: stale)],
            now: now
        )

        XCTAssertFalse(summary.hasAnyReportedWindow)
        XCTAssertTrue(try XCTUnwrap(summary.entries.first).windows.isEmpty)
        XCTAssertNil(summary.tightestWindow)
    }

    func testTheTightestWindowIsTheFullestOneAcrossEveryAgent() throws {
        let summary = AgentRateLimitQuotaSummary(entries: [
            .init(
                agent: .claudeCode,
                windows: [AgentRateLimitWindow(usedFraction: 0.2, windowMinutes: 300, resetsAt: nil)],
                observedAt: now
            ),
            .init(
                agent: .codex,
                windows: [
                    AgentRateLimitWindow(usedFraction: 0.9, windowMinutes: 300, resetsAt: nil),
                    AgentRateLimitWindow(usedFraction: 0.4, windowMinutes: 10_080, resetsAt: nil),
                ],
                observedAt: now
            ),
        ])

        let tightest = try XCTUnwrap(summary.tightestWindow)
        XCTAssertEqual(tightest.agent, .codex)
        XCTAssertEqual(AgentRateLimitQuotaCopy.percent(tightest.window.usedFraction), 90)
    }

    func testAnEmptyIndexProducesNoEntries() {
        XCTAssertTrue(AgentRateLimitQuotaSummary.make(records: [], now: now).isEmpty)
        XCTAssertNil(AgentRateLimitQuotaSummary.empty.tightestWindow)
    }
}

/// End-to-end through the scanner: the quota has to come out of a transcript
/// string, because that is the only input the real pipeline ever has.
final class AgentRateLimitQuotaScannerTests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_781_961_000)

    private func codexLine(usedPercent: Double, windowMinutes: Int, resetsAt: Int, at: String) -> String {
        """
        {"timestamp":"\(at)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12},\
        "last_token_usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12},\
        "model_context_window":237500},\
        "rate_limits":{"limit_id":"codex","primary":{"used_percent":\(usedPercent),\
        "window_minutes":\(windowMinutes),"resets_at":\(resetsAt)},"secondary":null}}}
        """
    }

    func testACodexTranscriptCarriesItsQuotaThroughTheScanner() throws {
        let record = try XCTUnwrap(CodexSessionScanner().parse(
            lines: [
                codexLine(usedPercent: 4, windowMinutes: 300, resetsAt: 1_781_961_059, at: "2026-06-20T17:00:00Z"),
                codexLine(usedPercent: 32, windowMinutes: 300, resetsAt: 1_781_970_000, at: "2026-06-20T17:10:00Z"),
            ],
            fileURL: URL(fileURLWithPath: "/tmp/rollout-2026-06-20T17-10-34-019ee414-e119-78b3-869f-c8171d62ddcc.jsonl"),
            modifiedAt: modified
        ))

        let quota = try XCTUnwrap(record.rateLimitQuota)
        // The last reading wins, and it is timestamped by the record that
        // carried it rather than by the file's mtime.
        XCTAssertEqual(AgentRateLimitQuotaCopy.percent(quota.windows[0].usedFraction), 32)
        XCTAssertEqual(quota.windows[0].resetsAt, Date(timeIntervalSince1970: 1_781_970_000))
        XCTAssertEqual(
            quota.observedAt,
            AgentSessionTimestampParser().date(from: "2026-06-20T17:10:00Z")
        )
    }

    /// The measured claim about Claude Code: nothing under `~/.claude` carries
    /// a rate-limit field, so the scanner must not manufacture one. If a future
    /// Claude Code starts writing quota to the transcript, this test is the
    /// place that should fail first.
    func testAClaudeTranscriptNeverProducesAQuota() throws {
        let record = try XCTUnwrap(ClaudeSessionScanner().parse(
            lines: [
                #"{"type":"user","sessionId":"s1","cwd":"/tmp","timestamp":"2026-06-20T17:00:00Z","message":{"role":"user","content":"hi"}}"#,
                #"{"type":"assistant","sessionId":"s1","timestamp":"2026-06-20T17:00:05Z","message":{"model":"claude-opus-5","usage":{"input_tokens":9,"output_tokens":3}}}"#,
            ],
            fileURL: URL(fileURLWithPath: "/tmp/s1.jsonl"),
            modifiedAt: modified
        ))

        XCTAssertNil(record.rateLimitQuota)
    }

    func testATranscriptWithoutRateLimitsLeavesTheQuotaUnset() throws {
        let record = try XCTUnwrap(CodexSessionScanner().parse(
            lines: [
                #"{"timestamp":"2026-06-20T17:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#,
            ],
            fileURL: URL(fileURLWithPath: "/tmp/rollout-2026-06-20T17-10-34-019ee414-e119-78b3-869f-c8171d62ddcc.jsonl"),
            modifiedAt: modified
        ))

        XCTAssertNil(record.rateLimitQuota)
    }
}

/// What the bar condenses the whole picture down to, and what it does when
/// there is nothing to condense.
final class TerminalStatusBarQuotaComposerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testTheBarShowsTheFullestWindowAndNamesIt() {
        let summary = TerminalStatusBarQuotaComposer.summary(
            for: AgentRateLimitQuotaSummary(entries: [
                .init(
                    agent: .codex,
                    windows: [
                        AgentRateLimitWindow(
                            usedFraction: 0.57,
                            windowMinutes: 300,
                            resetsAt: now.addingTimeInterval(122_400)
                        ),
                        AgentRateLimitWindow(usedFraction: 0.11, windowMinutes: 10_080, resetsAt: nil),
                    ],
                    observedAt: now
                ),
            ]),
            now: now,
            language: .english
        )

        XCTAssertTrue(summary.isPresent)
        XCTAssertEqual(summary.label, "Codex 5h")
        XCTAssertEqual(summary.percentText, "57%")
        XCTAssertEqual(summary.severity, .normal)
        XCTAssertTrue(summary.tooltip.contains("Resets in 1d 10h"))
    }

    /// Not "—". A quota nobody reports is not a metric that is temporarily
    /// unavailable, so the segment goes away rather than reserving space for a
    /// number that will never arrive.
    func testNothingReportedRendersAsAbsentRatherThanUnknown() {
        let summary = TerminalStatusBarQuotaComposer.summary(
            for: AgentRateLimitQuotaSummary(entries: [
                .init(agent: .claudeCode, windows: [], observedAt: nil),
            ]),
            now: now,
            language: .english
        )

        XCTAssertFalse(summary.isPresent)
        XCTAssertEqual(summary, .absent)
    }

    func testSeverityClimbsWithConsumption() {
        func severity(_ fraction: Double) -> TerminalStatusBarSeverity {
            TerminalStatusBarQuotaComposer.summary(
                for: AgentRateLimitQuotaSummary(entries: [
                    .init(
                        agent: .codex,
                        windows: [
                            AgentRateLimitWindow(
                                usedFraction: fraction,
                                windowMinutes: 300,
                                resetsAt: nil
                            ),
                        ],
                        observedAt: now
                    ),
                ]),
                now: now,
                language: .english
            ).severity
        }

        XCTAssertEqual(severity(0.5), .normal)
        XCTAssertEqual(severity(0.85), .warning)
        XCTAssertEqual(severity(1), .error)
    }
}

/// The two views that render a meter, checked against real AppKit layout
/// rather than against their source text.
@MainActor
final class AgentQuotaMeterRenderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func summary(fraction: Double) -> AgentRateLimitQuotaSummary {
        AgentRateLimitQuotaSummary(entries: [
            .init(
                agent: .codex,
                windows: [
                    AgentRateLimitWindow(
                        usedFraction: fraction,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(15_120)
                    ),
                ],
                observedAt: now
            ),
        ])
    }

    func testTheSectionCollapsesToNothingWhenNoAgentReports() {
        let view = TerminalAgentQuotaSummaryView(frame: NSRect(x: 0, y: 0, width: 260, height: 0))
        view.update(
            summary: AgentRateLimitQuotaSummary(entries: [
                .init(agent: .claudeCode, windows: [], observedAt: nil),
            ]),
            now: now
        )
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.frame.height, 0)
    }

    func testTheSectionShowsOneRowPerLiveWindow() {
        let view = TerminalAgentQuotaSummaryView(frame: NSRect(x: 0, y: 0, width: 260, height: 0))
        view.update(
            summary: AgentRateLimitQuotaSummary(entries: [
                .init(
                    agent: .codex,
                    windows: [
                        AgentRateLimitWindow(usedFraction: 0.3, windowMinutes: 300, resetsAt: nil),
                        AgentRateLimitWindow(usedFraction: 0.1, windowMinutes: 10_080, resetsAt: nil),
                    ],
                    observedAt: now
                ),
                // Reports nothing, so it contributes no row to the section.
                .init(agent: .claudeCode, windows: [], observedAt: nil),
            ]),
            now: now
        )
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(Self.meterRows(in: view).count, 2)
    }

    /// The meter is the reading: its fill has to track the fraction, and a
    /// nearly-empty window still has to draw something rather than vanish.
    func testTheFillTracksTheFractionAndNeverDisappearsEntirely() {
        let width: CGFloat = 200
        func fillWidth(for fraction: Double) -> CGFloat {
            let meter = AgentQuotaMeterView(frame: NSRect(x: 0, y: 0, width: width, height: 4))
            meter.update(fraction: fraction, pressure: .comfortable, theme: .dark)
            meter.layoutSubtreeIfNeeded()
            return meter.layer?.sublayers?.last?.frame.width ?? -1
        }

        XCTAssertEqual(fillWidth(for: 0), 0)
        XCTAssertEqual(fillWidth(for: 0.5), width / 2, accuracy: 0.5)
        XCTAssertEqual(fillWidth(for: 1), width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(
            fillWidth(for: 0.0001),
            DesignTokens.Component.AgentQuota.meterMinimumFillWidthPX
        )
    }

    /// Approaching the limit is a status, so it steps onto the theme's warning
    /// and error rungs — never onto the daily-spend ramp, which encodes
    /// magnitude rather than trouble.
    func testTheMeterUsesStatusColorsAndNotTheSpendRamp() {
        let theme = DesignTokens.ChromeTheme.dark
        XCTAssertEqual(AgentQuotaMeterRowView.valueColor(for: .comfortable, theme: theme), theme.textSecondary)
        XCTAssertEqual(AgentQuotaMeterRowView.valueColor(for: .warning, theme: theme), theme.warning)
        XCTAssertEqual(AgentQuotaMeterRowView.valueColor(for: .exhausted, theme: theme), theme.error)

        for pressure in [AgentRateLimitQuotaCopy.Pressure.comfortable, .warning, .exhausted] {
            let color = AgentQuotaMeterRowView.valueColor(for: pressure, theme: theme)
            XCTAssertNotEqual(color, theme.usageRampLow)
            XCTAssertNotEqual(color, theme.usageRampHigh)
        }
    }

    func testTheSectionStaysReadableInBothThemes() {
        for theme in [DesignTokens.ChromeTheme.dark, .light] {
            let view = TerminalAgentQuotaSummaryView(frame: NSRect(x: 0, y: 0, width: 260, height: 0))
            view.applyChromeTheme(theme)
            view.update(summary: summary(fraction: 0.42), now: now)
            view.layoutSubtreeIfNeeded()

            XCTAssertFalse(view.isHidden)
            XCTAssertEqual(Self.meterRows(in: view).count, 1)
        }
    }

    /// The popover is the only surface that explains a missing agent.
    func testThePopoverExplainsAnAgentThatReportsNothing() {
        let view = TerminalStatusBarQuotaView(
            summary: AgentRateLimitQuotaSummary(entries: [
                .init(agent: .claudeCode, windows: [], observedAt: nil),
                .init(
                    agent: .codex,
                    windows: [AgentRateLimitWindow(usedFraction: 0.2, windowMinutes: 300, resetsAt: nil)],
                    observedAt: now
                ),
            ]),
            now: now,
            theme: .dark
        )
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(Self.meterRows(in: view).count, 1)
        let texts = Self.labelTexts(in: view)
        XCTAssertTrue(texts.contains {
            $0 == AgentRateLimitQuotaCopy.notReportedSummary(agent: .claudeCode)
        })
    }

    /// A fresh window has no index yet, so the segment must not reserve a hover
    /// target for a number that may never arrive.
    func testTheStatusBarSegmentStartsHiddenAndAppearsOnlyWhenQuotaArrives() {
        let segment = TerminalStatusBarQuotaSegmentView(frame: .zero)

        XCTAssertTrue(segment.isHidden)

        segment.update(
            summary: TerminalStatusBarQuotaComposer.summary(
                for: summary(fraction: 0.42),
                now: now,
                language: .english
            ),
            visibility: .full
        )
        XCTAssertFalse(segment.isHidden)

        // Narrow enough to drop the quota segment: it goes whole, because a
        // meter without its percentage says nothing.
        segment.update(
            summary: segment.currentSummary,
            visibility: TerminalStatusBarLayoutPolicy.visibility(barWidthPX: 300)
        )
        XCTAssertTrue(segment.isHidden)
    }

    private static func meterRows(in view: NSView) -> [AgentQuotaMeterRowView] {
        var found: [AgentQuotaMeterRowView] = []
        for subview in view.subviews {
            if let row = subview as? AgentQuotaMeterRowView {
                found.append(row)
            }
            found.append(contentsOf: meterRows(in: subview))
        }
        return found
    }

    private static func labelTexts(in view: NSView) -> [String] {
        var found: [String] = []
        for subview in view.subviews {
            if let field = subview as? NSTextField {
                found.append(field.stringValue)
            }
            found.append(contentsOf: labelTexts(in: subview))
        }
        return found
    }
}
