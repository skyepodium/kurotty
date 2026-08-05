import Foundation
import XCTest
@testable import KurottyApp

/// The two agents report token usage in opposite shapes. Claude writes a fresh
/// block per assistant message, Codex writes a running total on every event, so
/// treating them alike silently multiplies one of the two.
final class AgentTokenUsageParsingTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(AgentTranscriptJSON.object(from: json))
    }

    func testClaudeIncrementsAreReadPerMessage() throws {
        let record = try object("""
        {"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":12,"output_tokens":340,"cache_read_input_tokens":9000,"cache_creation_input_tokens":210}}}
        """)
        let usage = try XCTUnwrap(AgentTokenUsageParsing.claudeIncrement(in: record))
        XCTAssertEqual(usage.inputTokens, 12)
        XCTAssertEqual(usage.outputTokens, 340)
        XCTAssertEqual(usage.cacheReadTokens, 9000)
        XCTAssertEqual(usage.cacheWriteTokens, 210)
        XCTAssertEqual(usage.model, "claude-opus-5")
        XCTAssertEqual(usage.totalTokens, 9562)
    }

    func testARecordWithoutAUsageBlockContributesNothing() throws {
        let record = try object(#"{"type":"user","message":{"role":"user","content":"hi"}}"#)
        XCTAssertNil(AgentTokenUsageParsing.claudeIncrement(in: record))
    }

    func testClaudeIncrementsAddUpAndTheLastModelWins() {
        let first = AgentTokenUsage(
            inputTokens: 10, outputTokens: 100,
            cacheReadTokens: 1000, cacheWriteTokens: 5, model: "claude-opus-5"
        )
        let second = AgentTokenUsage(
            inputTokens: 3, outputTokens: 40,
            cacheReadTokens: 200, cacheWriteTokens: 0, model: "claude-fable-5"
        )
        let sum = first + second
        XCTAssertEqual(sum.inputTokens, 13)
        XCTAssertEqual(sum.outputTokens, 140)
        XCTAssertEqual(sum.cacheReadTokens, 1200)
        XCTAssertEqual(sum.cacheWriteTokens, 5)
        XCTAssertEqual(sum.model, "claude-fable-5")
    }

    func testCodexReportsARunningTotalWithCachedInputFoldedIntoInput() throws {
        let payload = try object("""
        {"type":"token_count","info":{"total_token_usage":{"input_tokens":24566,"cached_input_tokens":2432,"output_tokens":369,"total_tokens":24935}}}
        """)
        let usage = try XCTUnwrap(AgentTokenUsageParsing.codexRunningTotal(in: payload))
        // Codex counts cached input inside input_tokens; splitting it back out
        // keeps `inputTokens` meaning the same thing it does for Claude.
        XCTAssertEqual(usage.inputTokens, 24566 - 2432)
        XCTAssertEqual(usage.cacheReadTokens, 2432)
        XCTAssertEqual(usage.outputTokens, 369)
    }

    func testAnEventWithoutTotalsIsIgnored() throws {
        let payload = try object(#"{"type":"message","role":"assistant"}"#)
        XCTAssertNil(AgentTokenUsageParsing.codexRunningTotal(in: payload))
    }

    func testNegativeAndStringCountsAreCoerced() throws {
        let record = try object("""
        {"type":"assistant","message":{"usage":{"input_tokens":"48","output_tokens":-5}}}
        """)
        let usage = try XCTUnwrap(AgentTokenUsageParsing.claudeIncrement(in: record))
        XCTAssertEqual(usage.inputTokens, 48)
        XCTAssertEqual(usage.outputTokens, 0)
    }
}

/// The strip must not reflow while a session runs, so the formatter keeps a
/// stable width as the value climbs through each magnitude.
final class AgentTokenUsageFormatterTests: XCTestCase {
    func testCompactFormattingAtEveryMagnitude() {
        XCTAssertEqual(AgentTokenUsageFormatter.compact(0), "0")
        XCTAssertEqual(AgentTokenUsageFormatter.compact(812), "812")
        XCTAssertEqual(AgentTokenUsageFormatter.compact(1_000), "1.0K")
        XCTAssertEqual(AgentTokenUsageFormatter.compact(24_600), "25K")
        XCTAssertEqual(AgentTokenUsageFormatter.compact(999_999), "1000K")
        XCTAssertEqual(AgentTokenUsageFormatter.compact(1_280_000), "1.28M")
        XCTAssertEqual(AgentTokenUsageFormatter.compact(283_030_000), "283.03M")
    }
}

final class AgentTokenUsageSummaryTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 12))!

    private func record(daysAgo: Int, tokens: Int) -> AgentSessionRecord {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return AgentSessionRecord(
            agent: .claudeCode,
            sessionID: "s\(daysAgo)-\(tokens)",
            title: "t",
            cwd: "/tmp",
            updatedAt: date,
            createdAt: date,
            messageCount: 1,
            filePath: "/tmp/x.jsonl",
            tokenUsage: AgentTokenUsage(
                inputTokens: tokens, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0, model: nil
            )
        )
    }

    func testTheWindowHasOneEntryPerDayIncludingEmptyOnes() {
        let summary = AgentTokenUsageSummary.make(
            records: [record(daysAgo: 0, tokens: 500)],
            now: now,
            dayCount: 14,
            calendar: calendar
        )
        XCTAssertEqual(summary.days.count, 14)
        XCTAssertEqual(summary.days.filter { $0.totalTokens == 0 }.count, 13)
        XCTAssertEqual(summary.days.last?.totalTokens, 500)
    }

    func testSessionsOnTheSameDayAreCombined() {
        let summary = AgentTokenUsageSummary.make(
            records: [record(daysAgo: 0, tokens: 500), record(daysAgo: 0, tokens: 250)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(summary.today.totalTokens, 750)
        XCTAssertEqual(summary.sessionCount, 2)
    }

    func testSessionsOlderThanTheWindowAreExcluded() {
        let summary = AgentTokenUsageSummary.make(
            records: [record(daysAgo: 20, tokens: 900), record(daysAgo: 1, tokens: 100)],
            now: now,
            dayCount: 14,
            calendar: calendar
        )
        XCTAssertEqual(summary.window.totalTokens, 100)
        XCTAssertEqual(summary.sessionCount, 1)
    }

    func testTheOldestDayInTheWindowIsKept() {
        let summary = AgentTokenUsageSummary.make(
            records: [record(daysAgo: 13, tokens: 70)],
            now: now,
            dayCount: 14,
            calendar: calendar
        )
        XCTAssertEqual(summary.days.first?.totalTokens, 70)
        XCTAssertEqual(summary.window.totalTokens, 70)
    }

    func testPeakDrivesTheBarScale() {
        let summary = AgentTokenUsageSummary.make(
            records: [record(daysAgo: 3, tokens: 4_000), record(daysAgo: 0, tokens: 1_000)],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(summary.peakDayTokens, 4_000)
    }

    func testSessionsWithoutUsageDoNotCountAsSessions() {
        let empty = AgentSessionRecord(
            agent: .codex, sessionID: "e", title: "t", cwd: "/tmp",
            updatedAt: now, createdAt: now, messageCount: 3, filePath: "/tmp/e.jsonl"
        )
        let summary = AgentTokenUsageSummary.make(records: [empty], now: now, calendar: calendar)
        XCTAssertEqual(summary.sessionCount, 0)
        XCTAssertTrue(summary.window.isEmpty)
    }

    func testEveryUsageStringResolvesInEveryLanguage() {
        let keys: [L10nKey] = [
            .agentUsageToday, .agentUsageInput, .agentUsageOutput,
            .agentUsageCache, .agentUsageAccessibility,
        ]
        for language in AppLanguage.allCases {
            for key in keys {
                XCTAssertTrue(
                    AppLocalization.hasTranslation(for: key, language: language),
                    "\(key) is missing for \(language.rawValue)"
                )
            }
        }
    }
}
