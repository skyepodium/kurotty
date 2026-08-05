import Foundation
import XCTest
@testable import KurottyApp

/// The context window is the one number in this feature that cannot be guessed.
/// Codex writes it into the transcript; Claude never does, so it can only come
/// from the model name, and a model that is not listed has to stay unknown.
/// Substituting a plausible default would produce a confidently wrong "how much
/// room is left", which is worse than declining to answer.
final class AgentModelContextWindowTests: XCTestCase {
    func testKnownModelsResolveToTheirWindow() {
        XCTAssertEqual(AgentModelContextWindow.tokens(forModel: "claude-opus-5"), 1_000_000)
        XCTAssertEqual(AgentModelContextWindow.tokens(forModel: "claude-fable-5"), 1_000_000)
        XCTAssertEqual(AgentModelContextWindow.tokens(forModel: "claude-sonnet-5"), 1_000_000)
        XCTAssertEqual(AgentModelContextWindow.tokens(forModel: "claude-haiku-4-5"), 200_000)
    }

    func testADatedSnapshotResolvesToItsFamily() {
        // Real transcripts carry this exact id.
        XCTAssertEqual(
            AgentModelContextWindow.tokens(forModel: "claude-haiku-4-5-20251001"),
            200_000
        )
    }

    func testAModelOutsideTheTableIsUnknown() {
        // Legacy models whose window this table does not claim to know, plus
        // the synthetic entries Claude writes for cancelled turns.
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "claude-sonnet-4-5"))
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "claude-opus-4-1"))
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "<synthetic>"))
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "gpt-5.6-sol"))
    }

    func testAbsentOrBlankModelIsUnknown() {
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: nil))
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "   "))
    }

    func testAShorterEntryDoesNotSwallowALongerModelID() {
        // `claude-haiku-4-5` must not match `claude-haiku-4-50` by prefix, and
        // a sonnet id must never resolve through an unrelated family.
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "claude-haiku-4-50"))
        XCTAssertNil(AgentModelContextWindow.tokens(forModel: "claude-sonnet"))
    }
}

/// Occupancy is measured, the rate is estimated, and the type has to keep
/// saying which is which even when one of them is missing.
final class AgentContextForecastTests: XCTestCase {
    private func limit(_ tokens: Int, _ source: AgentContextForecast.LimitSource = .transcript)
        -> AgentContextForecast.Limit
    {
        AgentContextForecast.Limit(tokens: tokens, source: source)
    }

    /// Occupancy climbing by a fixed step, so the median growth is that step.
    private func samples(from start: Int, step: Int, count: Int) -> [Int] {
        (0..<count).map { start + $0 * step }
    }

    func testUsedTokensIsTheLastSampleNotTheSum() {
        // The whole point of sampling a level rather than summing increments.
        let forecast = AgentContextForecast.make(
            samples: [10_000, 20_000, 30_000],
            limit: limit(100_000)
        )
        XCTAssertEqual(forecast.usedTokens, 30_000)
    }

    func testTheGrowthRateIsTheMedianStep() {
        let forecast = AgentContextForecast.make(
            samples: samples(from: 1_000, step: 500, count: 12),
            limit: limit(100_000)
        )
        XCTAssertEqual(forecast.tokensPerTurn, 500)
    }

    func testOneEnormousStepDoesNotMoveTheRate() {
        // A bounded head/tail read joins two distant points in the session, so
        // exactly one step is enormous. The median has to absorb it; a mean
        // would not. Measured on a real transcript, the mean went from 1,523 to
        // 85,111 tokens per turn on the same session when read this way.
        var withSeam = samples(from: 1_000, step: 500, count: 12)
        withSeam.insert(600_000, at: 6)
        withSeam.insert(600_500, at: 7)
        let forecast = AgentContextForecast.make(samples: withSeam, limit: limit(1_000_000))
        XCTAssertEqual(forecast.tokensPerTurn, 500)
    }

    func testCompactionStepsAreNotTreatedAsGrowth() {
        // A session that compacted drops sharply. That is not a rate.
        let forecast = AgentContextForecast.make(
            samples: [10_000, 10_400, 10_800, 11_200, 11_600, 12_000, 4_000, 4_400],
            limit: limit(100_000)
        )
        XCTAssertEqual(forecast.tokensPerTurn, 400)
        XCTAssertEqual(forecast.usedTokens, 4_400)
    }

    func testTooFewStepsReportNoRateAtAll() {
        // Below the minimum a single seam step *is* the median, which is how a
        // real two-sample session estimated 162,948 tokens per turn.
        let forecast = AgentContextForecast.make(
            samples: [12_000, 186_574],
            limit: limit(237_500)
        )
        XCTAssertNil(forecast.tokensPerTurn)
        XCTAssertNil(forecast.remainingTurns)
        // The measured half survives even when the estimated half cannot.
        XCTAssertEqual(forecast.usedTokens, 186_574)
        XCTAssertEqual(forecast.pressure, .comfortable)
    }

    // MARK: - Turn estimate across the range

    func testTurnEstimateAtLowUsage() {
        let forecast = AgentContextForecast.make(
            samples: samples(from: 1_000, step: 1_000, count: 11),
            limit: limit(1_000_000)
        )
        XCTAssertEqual(forecast.usedTokens, 11_000)
        XCTAssertEqual(forecast.tokensPerTurn, 1_000)
        XCTAssertEqual(forecast.remainingTokens, 989_000)
        XCTAssertEqual(forecast.remainingTurns, 989)
        XCTAssertEqual(forecast.pressure, .comfortable)
    }

    func testTurnEstimateAtHighUsage() {
        // Same rate, nearly full window: the estimate collapses to a handful.
        let forecast = AgentContextForecast.make(
            samples: samples(from: 985_000, step: 1_000, count: 11),
            limit: limit(1_000_000)
        )
        XCTAssertEqual(forecast.usedTokens, 995_000)
        XCTAssertEqual(forecast.tokensPerTurn, 1_000)
        XCTAssertEqual(forecast.remainingTurns, 5)
        XCTAssertEqual(forecast.pressure, .warning)
    }

    func testAFullWindowLeavesNoTurns() {
        let forecast = AgentContextForecast.make(
            samples: samples(from: 200_000, step: 1_000, count: 11) + [1_000_000],
            limit: limit(1_000_000)
        )
        XCTAssertEqual(forecast.remainingTokens, 0)
        XCTAssertEqual(forecast.remainingTurns, 0)
    }

    // MARK: - Boundaries

    func testASessionPastItsWindowReportsOverOneHundredPercent() {
        // Observed on a real Claude session that reached 1,003,667 before the
        // agent compacted it. Clamping this away would hide the one moment the
        // meter most needs to be believed.
        let forecast = AgentContextForecast.make(
            samples: samples(from: 995_000, step: 1_000, count: 6) + [1_003_667],
            limit: limit(1_000_000, .modelTable)
        )
        XCTAssertEqual(forecast.usedTokens, 1_003_667)
        XCTAssertEqual(forecast.pressure, .exhausted)
        XCTAssertEqual(forecast.remainingTokens, 0)
        XCTAssertEqual(forecast.remainingTurns, 0)
        let fraction = try? XCTUnwrap(forecast.usedFraction)
        XCTAssertGreaterThan(fraction ?? 0, 1.0)
    }

    func testWithoutALimitEverythingDerivedIsNil() {
        let forecast = AgentContextForecast.make(
            samples: samples(from: 1_000, step: 500, count: 12),
            limit: nil
        )
        // Measured occupancy and rate survive; nothing that needs a window does.
        XCTAssertEqual(forecast.usedTokens, 6_500)
        XCTAssertEqual(forecast.tokensPerTurn, 500)
        XCTAssertNil(forecast.usedFraction)
        XCTAssertNil(forecast.remainingTokens)
        XCTAssertNil(forecast.remainingTurns)
        XCTAssertNil(forecast.pressure)
    }

    func testNoSamplesIsEmpty() {
        let forecast = AgentContextForecast.make(samples: [], limit: limit(1_000_000))
        XCTAssertTrue(forecast.isEmpty)
        XCTAssertEqual(forecast.usedTokens, 0)
        XCTAssertNil(forecast.tokensPerTurn)
        XCTAssertEqual(AgentContextForecast.unknown.usedTokens, 0)
        XCTAssertTrue(AgentContextForecast.unknown.isEmpty)
    }

    func testPressureThresholds() {
        func pressure(used: Int) -> AgentContextForecast.Pressure? {
            AgentContextForecast.make(samples: [used], limit: limit(1_000_000)).pressure
        }
        XCTAssertEqual(pressure(used: 799_999), .comfortable)
        XCTAssertEqual(pressure(used: 800_000), .warning)
        XCTAssertEqual(pressure(used: 999_999), .warning)
        XCTAssertEqual(pressure(used: 1_000_000), .exhausted)
    }

    // MARK: - Builder

    func testATranscriptWindowBeatsTheModelTable() {
        var builder = AgentContextForecastBuilder()
        builder.observe(occupancyTokens: 10_000)
        builder.observe(transcriptContextWindow: 237_500)
        let forecast = builder.forecast(model: "claude-opus-5")
        XCTAssertEqual(forecast.limit?.tokens, 237_500)
        XCTAssertEqual(forecast.limit?.source, .transcript)
    }

    func testTheModelTableIsTheFallback() {
        var builder = AgentContextForecastBuilder()
        builder.observe(occupancyTokens: 10_000)
        let forecast = builder.forecast(model: "claude-opus-5")
        XCTAssertEqual(forecast.limit?.tokens, 1_000_000)
        XCTAssertEqual(forecast.limit?.source, .modelTable)
    }

    func testZeroAndNegativeObservationsAreIgnored() {
        var builder = AgentContextForecastBuilder()
        builder.observe(occupancyTokens: 0)
        builder.observe(transcriptContextWindow: 0)
        let forecast = builder.forecast(model: nil)
        XCTAssertTrue(forecast.isEmpty)
        XCTAssertNil(forecast.limit)
    }
}
