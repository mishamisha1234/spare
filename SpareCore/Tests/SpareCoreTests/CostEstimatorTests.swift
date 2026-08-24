import XCTest
@testable import SpareCore

final class CostEstimatorTests: XCTestCase {

    func testPricesMatchTheGenerationModel() {
        // claude-opus-5: $5 / $25 per million tokens.
        XCTAssertEqual(CostEstimator.inputPricePerMillion, 5.00, accuracy: 0.001)
        XCTAssertEqual(CostEstimator.outputPricePerMillion, 25.00, accuracy: 0.001)
    }

    func testTokenEstimateFromCharacters() {
        XCTAssertEqual(CostEstimator.estimatedTokens(forCharacters: 0), 0)
        XCTAssertEqual(CostEstimator.estimatedTokens(forCharacters: 36), 10)
        XCTAssertEqual(CostEstimator.estimatedTokens(forCharacters: 37), 11, "must round up")
    }

    func testTokenEstimateFromWordsIsInAPlausibleRange() {
        // English prose is roughly 1.3-1.6 tokens per word.
        let tokens = CostEstimator.estimatedTokens(forWords: 1_000)
        XCTAssertGreaterThan(tokens, 1_200)
        XCTAssertLessThan(tokens, 1_800)
    }

    func testCostOfPlainUsage() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(CostEstimator.cost(of: usage), 30.00, accuracy: 0.001)
    }

    func testCachedReadsAreCheaperThanFreshInput() {
        let fresh = CostEstimator.cost(of: TokenUsage(inputTokens: 100_000))
        let cached = CostEstimator.cost(of: TokenUsage(cacheReadInputTokens: 100_000))
        XCTAssertLessThan(cached, fresh)
        XCTAssertEqual(cached, fresh * 0.1, accuracy: 0.0001)
    }

    func testCacheWritesCostMoreThanFreshInput() {
        let fresh = CostEstimator.cost(of: TokenUsage(inputTokens: 100_000))
        let written = CostEstimator.cost(of: TokenUsage(cacheCreationInputTokens: 100_000))
        XCTAssertEqual(written, fresh * 1.25, accuracy: 0.0001)
    }

    func testZeroUsageIsFree() {
        XCTAssertEqual(CostEstimator.cost(of: TokenUsage()), 0, accuracy: 0.0001)
    }

    func testLessonCostRisesWithWindowLength() {
        let costs = TimeWindow.allCases.map { CostEstimator.estimatedLessonCost(window: $0) }
        for (shorter, longer) in zip(costs, costs.dropFirst()) {
            XCTAssertLessThan(shorter, longer, "a longer window must not cost less")
        }
    }

    /// The two-pass pipeline is the main cost driver; the estimate must reflect
    /// that rather than pricing a single pass.
    func testTwoPassEstimateExceedsASinglePass() {
        let window = TimeWindow.seven
        let bodyWords = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
        let singlePass = CostEstimator.cost(of: TokenUsage(
            inputTokens: CostEstimator.estimatedTokens(forWords: 700),
            outputTokens: CostEstimator.estimatedTokens(forWords: bodyWords)
        ))
        XCTAssertGreaterThan(CostEstimator.estimatedLessonCost(window: window), singlePass * 1.8)
    }

    func testSessionCostIncludesSuggestionsLessonAndRecall() {
        let window = TimeWindow.seven
        let session = CostEstimator.estimatedSessionCost(window: window)
        XCTAssertEqual(
            session,
            CostEstimator.estimatedSuggestionCost()
                + CostEstimator.estimatedLessonCost(window: window)
                + CostEstimator.estimatedRecallQuestionCost(window: window),
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(session, CostEstimator.estimatedLessonCost(window: window))
    }

    func testEstimatesLandInAPlausibleRangeForRealUse() {
        // Sanity bounds: a 3-minute lesson should cost cents, a 30-minute
        // mini-course should not cost dollars-plural.
        let short = CostEstimator.estimatedLessonCost(window: .three)
        XCTAssertGreaterThan(short, 0.001)
        XCTAssertLessThan(short, 0.20)

        let long = CostEstimator.estimatedLessonCost(window: .thirty)
        XCTAssertGreaterThan(long, 0.10)
        XCTAssertLessThan(long, 2.00)
    }

    func testSuggestionsAreCheaperThanAnyLesson() {
        XCTAssertLessThan(
            CostEstimator.estimatedSuggestionCost(),
            CostEstimator.estimatedLessonCost(window: .three)
        )
    }

    // MARK: - Per-model pricing

    /// Published list prices, checked against the numbers rather than against
    /// each other, so a transcription slip is visible.
    ///
    /// Sonnet is at its list $3/$15, not the introductory $2/$10 it is on
    /// until 2026-08-31. That is deliberate and the comment on the table says
    /// why: this figure feeds the spend ceiling, the free pool runs entirely
    /// on this model, and an error high stops generation slightly early while
    /// an error low sails past the ceiling.
    func testEachModelIsPricedAtItsPublishedRate() {
        let expected: [String: (input: Double, output: Double)] = [
            "claude-opus-5": (5, 25),
            "claude-sonnet-5": (3, 15),
        ]
        for (model, prices) in expected {
            let pricing = CostEstimator.pricing(for: model)
            XCTAssertEqual(pricing.inputPerMillion, prices.input, "\(model) input")
            XCTAssertEqual(pricing.outputPerMillion, prices.output, "\(model) output")
        }
        XCTAssertEqual(CostEstimator.modelPricing.count, expected.count)
    }

    func testAMillionTokensCostsTheListedAmount() {
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(CostEstimator.cost(of: usage, model: "claude-opus-5"), 30, accuracy: 0.0001)
        XCTAssertEqual(CostEstimator.cost(of: usage, model: "claude-sonnet-5"), 18, accuracy: 0.0001)
    }

    /// Haiku is priced nowhere, because it is used nowhere.
    ///
    /// A blind comparison across three durations and six topics found
    /// confident fabrications in all three of its lessons — an invented 1884
    /// act of Congress among them. Leaving it in the pricing table would be
    /// harmless on its own; leaving it in the table *and* the server's
    /// allowlist is how it quietly reappears in the next comparison run. It
    /// now prices as an unknown model, which is to say at the most expensive
    /// known rate.
    func testHaikuIsNotAPricedModel() {
        XCTAssertNil(CostEstimator.modelPricing["claude-haiku-4-5-20251001"])
        XCTAssertEqual(
            CostEstimator.pricing(for: "claude-haiku-4-5-20251001").inputPerMillion,
            CostEstimator.pricing(for: "claude-opus-5").inputPerMillion
        )
    }

    /// The point of the table, and it matters more now than it did when it was
    /// only about a comparison run: the free pool is written by Sonnet and the
    /// premium pool by Opus, so pricing both at the app's model's rate would
    /// overstate every free lesson by two thirds.
    func testTheSameTokensCostDifferentAmountsOnDifferentModels() {
        let usage = TokenUsage(inputTokens: 40_000, outputTokens: 8_000)
        let opus = CostEstimator.cost(of: usage, model: "claude-opus-5")
        let sonnet = CostEstimator.cost(of: usage, model: "claude-sonnet-5")
        XCTAssertGreaterThan(opus, sonnet)
        // Both rates scale by the same 3/5, so the ratio holds for any mix.
        XCTAssertEqual(opus / sonnet, 5.0 / 3.0, accuracy: 0.0001)
    }

    /// Over-estimating a bill is recoverable; under-estimating it is what the
    /// spend ceiling exists to prevent.
    func testAnUnknownModelIsPricedAtTheMostExpensiveKnownRate() {
        let usage = TokenUsage(inputTokens: 10_000, outputTokens: 2_000)
        XCTAssertEqual(
            CostEstimator.cost(of: usage, model: "some-model-nobody-has-priced"),
            CostEstimator.cost(of: usage, model: AnthropicAPI.model)
        )
        for pricing in CostEstimator.modelPricing.values {
            XCTAssertLessThanOrEqual(
                pricing.outputPerMillion,
                CostEstimator.pricing(for: AnthropicAPI.model).outputPerMillion,
                "the fallback must not be cheaper than a real model"
            )
        }
    }

    /// A usage event has carried a model since it was written. It used to price
    /// itself at the app's model regardless, which is invisible with one model
    /// and wrong with three.
    func testAUsageEventPricesItselfAtItsOwnModel() {
        let usage = TokenUsage(inputTokens: 100_000, outputTokens: 20_000)
        let opus = UsageEvent(
            kind: .lessonDraft, model: "claude-opus-5", usage: usage, occurredAt: Date()
        )
        let sonnet = UsageEvent(
            kind: .lessonDraft, model: "claude-sonnet-5", usage: usage, occurredAt: Date()
        )
        XCTAssertEqual(
            opus.estimatedCostUSD / sonnet.estimatedCostUSD, 5.0 / 3.0, accuracy: 0.0001
        )
    }

    func testCacheMultipliersApplyToTheModelsOwnInputRate() {
        let cached = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 1_000_000)
        // A cache read is a tenth of that model's input price: $0.50 on Opus,
        // $0.30 on Sonnet.
        XCTAssertEqual(
            CostEstimator.cost(of: cached, model: "claude-opus-5"), 0.5, accuracy: 0.0001
        )
        XCTAssertEqual(
            CostEstimator.cost(of: cached, model: "claude-sonnet-5"), 0.3, accuracy: 0.0001
        )
    }

    func testFormattingShowsSubCentValuesWithoutRoundingToZero() {
        XCTAssertEqual(CostEstimator.formatted(0.004), "$0.004")
        XCTAssertEqual(CostEstimator.formatted(0.42), "$0.42")
        XCTAssertEqual(CostEstimator.formatted(1.5), "$1.50")
        XCTAssertEqual(CostEstimator.formatted(0), "$0.00")
    }
}
