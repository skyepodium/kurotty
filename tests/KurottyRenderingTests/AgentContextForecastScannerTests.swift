import Foundation
import XCTest
@testable import KurottyApp

/// End-to-end over both on-disk shapes. The fixtures are trimmed copies of real
/// records, because the two agents disagree about almost everything: Codex
/// records the window and reports the last request's cost beside a running
/// total, while Claude records neither and only ever writes per-message usage.
final class AgentContextForecastScannerTests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_770_000_000)

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    // MARK: - Codex

    /// `total_token_usage` accumulates and `last_token_usage` does not. Reading
    /// the wrong one puts the session past its window on turn three.
    private func codexEvent(
        cumulative: Int,
        promptTokens: Int,
        cachedTokens: Int,
        outputTokens: Int,
        contextWindow: Int = 237_500
    ) -> String {
        """
        {"timestamp":"2026-08-01T09:57:35.855Z","type":"event_msg","payload":{"type":"token_count","info":\
        {"total_token_usage":{"input_tokens":\(cumulative),"cached_input_tokens":0,"output_tokens":0,\
        "total_tokens":\(cumulative)},\
        "last_token_usage":{"input_tokens":\(promptTokens),"cached_input_tokens":\(cachedTokens),\
        "cache_write_input_tokens":0,"output_tokens":\(outputTokens),"reasoning_output_tokens":0,\
        "total_tokens":\(promptTokens + outputTokens)},\
        "model_context_window":\(contextWindow)}}}
        """
    }

    func testCodexTakesTheWindowAndOccupancyFromTheTranscript() throws {
        let lines = (1...6).map { step in
            codexEvent(
                cumulative: step * 500_000,
                promptTokens: 30_000 + step * 1_000,
                cachedTokens: 6_912,
                outputTokens: 200
            )
        }
        let record = try XCTUnwrap(
            CodexSessionScanner().parse(
                lines: lines,
                fileURL: url("rollout-2026-08-01T09-57-35-019fbcc1-b38f-7f51-83f7-9866cc4e5837.jsonl"),
                modifiedAt: modified
            )
        )
        let forecast = record.contextForecast

        // Measured, straight off disk.
        XCTAssertEqual(forecast.limit?.tokens, 237_500)
        XCTAssertEqual(forecast.limit?.source, .transcript)
        // Last request only: prompt (36,000) plus reply (200).
        XCTAssertEqual(forecast.usedTokens, 36_200)
        // The running total reached 3,000,000 and must not have been used.
        XCTAssertLessThan(forecast.usedTokens, forecast.limit?.tokens ?? 0)
        XCTAssertEqual(record.tokenUsage.totalTokens, 3_000_000)
        // Estimated.
        XCTAssertEqual(forecast.tokensPerTurn, 1_000)
        XCTAssertEqual(forecast.remainingTurns, (237_500 - 36_200) / 1_000)
    }

    func testCodexHonoursTheLatestWindowWhenTheModelChanged() throws {
        let lines = [
            codexEvent(cumulative: 1, promptTokens: 10_000, cachedTokens: 0, outputTokens: 10,
                       contextWindow: 237_500),
            codexEvent(cumulative: 2, promptTokens: 11_000, cachedTokens: 0, outputTokens: 10,
                       contextWindow: 400_000),
        ]
        let record = try XCTUnwrap(
            CodexSessionScanner().parse(lines: lines, fileURL: url("rollout-a.jsonl"), modifiedAt: modified)
        )
        XCTAssertEqual(record.contextForecast.limit?.tokens, 400_000)
    }

    // MARK: - Claude

    /// Claude's per-message `usage` describes the whole prompt that message
    /// carried plus its reply, which is exactly the next request's floor.
    private func claudeMessage(
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        outputTokens: Int
    ) -> String {
        """
        {"type":"assistant","sessionId":"b7b8838b-e74c-4b3b-aa66-c739ae6421df",\
        "timestamp":"2026-08-01T09:57:35.855Z","cwd":"/Users/x/dev/kurotty",\
        "message":{"model":"\(model)","usage":{"input_tokens":\(inputTokens),\
        "cache_read_input_tokens":\(cacheReadTokens),\
        "cache_creation_input_tokens":\(cacheWriteTokens),"output_tokens":\(outputTokens)}}}
        """
    }

    private func claudeTranscript(model: String, steps: Int, step: Int) -> [String] {
        (1...steps).map { index in
            claudeMessage(
                model: model,
                inputTokens: 2,
                cacheReadTokens: 40_000 + index * step,
                cacheWriteTokens: 500,
                outputTokens: 300
            )
        }
    }

    func testClaudeDerivesTheWindowFromTheModelName() throws {
        let record = try XCTUnwrap(
            ClaudeSessionScanner().parse(
                lines: claudeTranscript(model: "claude-opus-5", steps: 8, step: 1_000),
                fileURL: url("b7b8838b-e74c-4b3b-aa66-c739ae6421df.jsonl"),
                modifiedAt: modified
            )
        )
        let forecast = record.contextForecast
        XCTAssertEqual(forecast.limit?.tokens, 1_000_000)
        // Derived from the model name, never read off disk.
        XCTAssertEqual(forecast.limit?.source, .modelTable)
        // 2 + (40_000 + 8_000) + 500 + 300
        XCTAssertEqual(forecast.usedTokens, 48_802)
        XCTAssertEqual(forecast.tokensPerTurn, 1_000)
        XCTAssertEqual(forecast.pressure, .comfortable)
    }

    func testClaudeOccupancyIsALevelWhileTokenUsageStaysASum() throws {
        let record = try XCTUnwrap(
            ClaudeSessionScanner().parse(
                lines: claudeTranscript(model: "claude-opus-5", steps: 8, step: 1_000),
                fileURL: url("b.jsonl"),
                modifiedAt: modified
            )
        )
        // The billing view keeps summing every message; the context view does
        // not. They must not be the same number.
        XCTAssertGreaterThan(record.tokenUsage.totalTokens, record.contextForecast.usedTokens)
    }

    func testClaudeWithAnUnlistedModelReportsNoLimit() throws {
        let record = try XCTUnwrap(
            ClaudeSessionScanner().parse(
                lines: claudeTranscript(model: "claude-sonnet-4-5", steps: 8, step: 1_000),
                fileURL: url("c.jsonl"),
                modifiedAt: modified
            )
        )
        let forecast = record.contextForecast
        // Occupancy is still measured; nothing that needs a window is invented.
        XCTAssertEqual(forecast.usedTokens, 48_802)
        XCTAssertNil(forecast.limit)
        XCTAssertNil(forecast.usedFraction)
        XCTAssertNil(forecast.remainingTurns)
        XCTAssertNil(forecast.pressure)
    }

    func testClaudeSessionAlreadyPastItsWindow() throws {
        var lines = claudeTranscript(model: "claude-opus-5", steps: 6, step: 1_000)
        lines.append(
            claudeMessage(
                model: "claude-opus-5",
                inputTokens: 2,
                cacheReadTokens: 1_002_000,
                cacheWriteTokens: 1_000,
                outputTokens: 665
            )
        )
        let record = try XCTUnwrap(
            ClaudeSessionScanner().parse(lines: lines, fileURL: url("d.jsonl"), modifiedAt: modified)
        )
        let forecast = record.contextForecast
        XCTAssertEqual(forecast.usedTokens, 1_003_667)
        XCTAssertEqual(forecast.pressure, .exhausted)
        XCTAssertEqual(forecast.remainingTurns, 0)
    }

    // MARK: - Nothing to say

    func testATranscriptWithNoTokenAccountingHasNoForecast() throws {
        let record = try XCTUnwrap(
            ClaudeSessionScanner().parse(
                lines: [
                    #"{"type":"user","sessionId":"s1","cwd":"/tmp","message":{"role":"user","content":"hi"}}"#,
                    #"{"type":"assistant","sessionId":"s1","message":{"model":"claude-opus-5","content":[]}}"#,
                ],
                fileURL: url("e.jsonl"),
                modifiedAt: modified
            )
        )
        XCTAssertTrue(record.contextForecast.isEmpty)
        XCTAssertEqual(record.contextForecast.usedTokens, 0)
        XCTAssertNil(record.contextForecast.usedFraction)
        XCTAssertNil(AgentContextForecastCopy.summary(for: record.contextForecast))
    }

    func testACodexSessionWithoutTokenCountEventsHasNoForecast() throws {
        let record = try XCTUnwrap(
            CodexSessionScanner().parse(
                lines: [
                    """
                    {"timestamp":"2026-08-01T09:57:35.855Z","type":"response_item",\
                    "payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}],\
                    "cwd":"/Users/x/dev/kurotty"}}
                    """,
                ],
                fileURL: url("rollout-f-019f8aba-21e0-7f51-83f7-9866cc4e5837.jsonl"),
                modifiedAt: modified
            )
        )
        XCTAssertTrue(record.contextForecast.isEmpty)
        XCTAssertNil(record.contextForecast.limit)
    }
}

/// The tooltip has to keep the measured half and the estimated half apart, and
/// has to resolve in every shipped language.
final class AgentContextForecastCopyTests: XCTestCase {
    private func forecast(
        used: Int,
        limitTokens: Int?,
        samples extra: [Int] = []
    ) -> AgentContextForecast {
        let limit = limitTokens.map {
            AgentContextForecast.Limit(tokens: $0, source: .modelTable)
        }
        return AgentContextForecast.make(samples: extra + [used], limit: limit)
    }

    func testTheSummaryStatesPercentAndWindow() throws {
        let copy = try XCTUnwrap(
            AgentContextForecastCopy.summary(
                for: forecast(used: 725_953, limitTokens: 1_000_000)
            )
        )
        XCTAssertTrue(copy.contains("73%"), copy)
        XCTAssertTrue(copy.contains("1.00M"), copy)
    }

    /// Assertions compare against the localized template rather than English
    /// literals, because the suite runs in whatever language the developer set.
    private func turnsPhrase(_ turns: Int) -> String {
        AppLocalization.format(.agentContextTurnsLeft, turns)
    }

    func testTheTurnEstimateAppearsOnlyWhenARateWasMeasured() throws {
        let rising = (0..<10).map { 500_000 + $0 * 1_000 }
        let measured = AgentContextForecast.make(
            samples: rising,
            limit: AgentContextForecast.Limit(tokens: 1_000_000, source: .modelTable)
        )
        let withRate = try XCTUnwrap(AgentContextForecastCopy.summary(for: measured))
        let turns = try XCTUnwrap(measured.remainingTurns)
        XCTAssertTrue(withRate.contains(turnsPhrase(turns)), withRate)

        // One sample: occupancy is known, the rate is not, so the sentence
        // simply stops rather than guessing.
        let single = forecast(used: 500_000, limitTokens: 1_000_000)
        XCTAssertNil(single.remainingTurns)
        let withoutRate = try XCTUnwrap(AgentContextForecastCopy.summary(for: single))
        XCTAssertFalse(withoutRate.contains(turnsPhrase(491)), withoutRate)
    }

    func testTheEnglishTurnEstimateIsMarkedApproximate() {
        // The tilde is what tells an English reader this half is a guess.
        XCTAssertTrue(
            AppLocalization.string(.agentContextTurnsLeft, language: .english).contains("~")
        )
    }

    func testAnUnknownWindowSaysSoInsteadOfShowingAPercentage() throws {
        let copy = try XCTUnwrap(
            AgentContextForecastCopy.summary(for: forecast(used: 48_802, limitTokens: nil))
        )
        XCTAssertFalse(copy.contains("%"), copy)
        XCTAssertTrue(copy.contains(AgentTokenUsageFormatter.compact(48_802)), copy)
    }

    func testAnOverfullWindowSaysOverLimitRatherThanZeroTurns() throws {
        let rising = (0..<10).map { 990_000 + $0 * 2_000 }
        let overfull = AgentContextForecast.make(
            samples: rising,
            limit: AgentContextForecast.Limit(tokens: 1_000_000, source: .modelTable)
        )
        let copy = try XCTUnwrap(AgentContextForecastCopy.summary(for: overfull))
        XCTAssertTrue(copy.contains(AppLocalization.string(.agentContextOverLimit)), copy)
        // "0 turns left" would read as a countdown that stalled rather than a
        // window that is already full.
        XCTAssertFalse(copy.contains(turnsPhrase(0)), copy)
    }

    func testPercentRounds() {
        XCTAssertEqual(AgentContextForecastCopy.percent(0.7259), 73)
        XCTAssertEqual(AgentContextForecastCopy.percent(1.0037), 100)
        XCTAssertEqual(AgentContextForecastCopy.percent(0.004), 0)
    }

    func testAccessibilityLabelOnlyExistsWhenTheMeterDoes() {
        XCTAssertNotNil(
            AgentContextForecastCopy.accessibilityLabel(
                for: forecast(used: 500_000, limitTokens: 1_000_000)
            )
        )
        XCTAssertNil(
            AgentContextForecastCopy.accessibilityLabel(for: forecast(used: 500_000, limitTokens: nil))
        )
    }

    func testEveryContextStringResolvesInEveryLanguage() {
        let keys: [L10nKey] = [
            .agentContextLabel, .agentContextOfLimit, .agentContextTurnsLeft,
            .agentContextOverLimit, .agentContextLimitUnknown, .agentContextAccessibility,
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

    func testFormattedStringsSubstituteInEveryLanguage() {
        // A dropped positional specifier would silently print the format string.
        for language in AppLanguage.allCases {
            let ofLimit = AppLocalization.string(.agentContextOfLimit, language: language)
            XCTAssertTrue(ofLimit.contains("%1$d"), "\(language.rawValue): \(ofLimit)")
            XCTAssertTrue(ofLimit.contains("%2$@"), "\(language.rawValue): \(ofLimit)")
            XCTAssertTrue(
                AppLocalization.string(.agentContextTurnsLeft, language: language).contains("%d")
            )
            XCTAssertTrue(
                AppLocalization.string(.agentContextLimitUnknown, language: language).contains("%@")
            )
        }
    }
}
