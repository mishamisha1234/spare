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
        let window = TimeWindow.ten
        let bodyWords = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
        let singlePass = CostEstimator.cost(of: TokenUsage(
            inputTokens: CostEstimator.estimatedTokens(forWords: 700),
            outputTokens: CostEstimator.estimatedTokens(forWords: bodyWords)
        ))
        XCTAssertGreaterThan(CostEstimator.estimatedLessonCost(window: window), singlePass * 1.8)
    }

    func testSessionCostIncludesSuggestionsLessonAndRecall() {
        let window = TimeWindow.ten
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

    func testFormattingShowsSubCentValuesWithoutRoundingToZero() {
        XCTAssertEqual(CostEstimator.formatted(0.004), "$0.004")
        XCTAssertEqual(CostEstimator.formatted(0.42), "$0.42")
        XCTAssertEqual(CostEstimator.formatted(1.5), "$1.50")
        XCTAssertEqual(CostEstimator.formatted(0), "$0.00")
    }
}
