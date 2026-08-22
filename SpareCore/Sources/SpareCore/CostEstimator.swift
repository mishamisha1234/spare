import Foundation

/// Rough per-lesson cost estimation, so Settings can show what a lesson costs
/// on the user's own key. Estimates only: token counts are approximated from
/// characters rather than tokenized, and the two-pass pipeline doubles output.
public enum CostEstimator {

    /// What one model's tokens cost.
    public struct ModelPricing: Sendable, Equatable {
        public var inputPerMillion: Double
        public var outputPerMillion: Double

        public init(inputPerMillion: Double, outputPerMillion: Double) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
        }
    }

    /// Published list prices, per million tokens.
    ///
    /// Only the base input and output rates differ between models; the cache
    /// multipliers below are the same 1.25x and 0.1x for all of them, so they
    /// stay separate rather than being repeated three times.
    ///
    /// This table exists because the batch tool can run one set of topics
    /// through several models to compare them, and a comparison whose cost
    /// column is computed at one model's prices is worse than no cost column.
    public static let modelPricing: [String: ModelPricing] = [
        "claude-opus-5": ModelPricing(inputPerMillion: 5, outputPerMillion: 25),
        "claude-sonnet-5": ModelPricing(inputPerMillion: 2, outputPerMillion: 10),
        "claude-haiku-4-5-20251001": ModelPricing(inputPerMillion: 1, outputPerMillion: 5),
    ]

    /// Falls back to the generation model's prices for anything unlisted.
    ///
    /// That is the most expensive entry in the table, which keeps the old
    /// behaviour of over-estimating rather than under-estimating a bill. It is
    /// the right default for the app, where the only model in play is the one
    /// it ships with; the batch tool names its models explicitly and never
    /// relies on it.
    public static func pricing(for model: String) -> ModelPricing {
        modelPricing[model] ?? modelPricing[AnthropicAPI.model]!
    }

    /// USD per million tokens for the generation model (claude-opus-5).
    public static var inputPricePerMillion: Double { pricing(for: AnthropicAPI.model).inputPerMillion }
    public static var outputPricePerMillion: Double { pricing(for: AnthropicAPI.model).outputPerMillion }
    /// Cached input reads bill at a tenth of the input rate.
    public static let cacheReadMultiplier = 0.1
    /// Five-minute cache writes bill at 1.25x the input rate.
    public static let cacheWriteMultiplier = 1.25

    /// Characters per token for English prose. Deliberately conservative:
    /// it is better to over-estimate the bill than under-estimate it.
    public static let charactersPerToken = 3.6

    public static func estimatedTokens(forCharacters characters: Int) -> Int {
        guard characters > 0 else { return 0 }
        return Int((Double(characters) / charactersPerToken).rounded(.up))
    }

    public static func estimatedTokens(forWords words: Int) -> Int {
        // ~5.7 characters per English word including the trailing space.
        estimatedTokens(forCharacters: Int(Double(words) * 5.7))
    }

    public static func cost(of usage: TokenUsage, model: String = AnthropicAPI.model) -> Double {
        let prices = pricing(for: model)
        let input = Double(usage.inputTokens) / 1_000_000 * prices.inputPerMillion
        let output = Double(usage.outputTokens) / 1_000_000 * prices.outputPerMillion
        let cacheWrite = Double(usage.cacheCreationInputTokens) / 1_000_000
            * prices.inputPerMillion * cacheWriteMultiplier
        let cacheRead = Double(usage.cacheReadInputTokens) / 1_000_000
            * prices.inputPerMillion * cacheReadMultiplier
        return input + output + cacheWrite + cacheRead
    }

    /// Estimated cost of generating one lesson end to end.
    ///
    /// Accounts for the two-pass pipeline: pass 1 produces the draft, then pass 2
    /// reads that draft as input *and* writes a comparable amount of output.
    public static func estimatedLessonCost(window: TimeWindow, promptWords: Int = 700) -> Double {
        let bodyWords = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
        let promptTokens = estimatedTokens(forWords: promptWords)
        let bodyTokens = estimatedTokens(forWords: bodyWords)

        // Pass 1: prompt in, draft out.
        let pass1 = TokenUsage(inputTokens: promptTokens, outputTokens: bodyTokens)
        // Pass 2: prompt + draft in, revision out.
        let pass2 = TokenUsage(inputTokens: promptTokens + bodyTokens, outputTokens: bodyTokens)

        return cost(of: pass1 + pass2)
    }

    /// Suggestions are cheap but happen more often than lessons.
    public static func estimatedSuggestionCost(promptWords: Int = 500) -> Double {
        cost(of: TokenUsage(
            inputTokens: estimatedTokens(forWords: promptWords),
            outputTokens: estimatedTokens(forWords: 120)
        ))
    }

    public static func estimatedRecallQuestionCost(window: TimeWindow) -> Double {
        let bodyWords = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
        return cost(of: TokenUsage(
            inputTokens: estimatedTokens(forWords: bodyWords + 150),
            outputTokens: estimatedTokens(forWords: 120)
        ))
    }

    /// What one complete session costs: suggestions, the lesson, and the recall
    /// question generated at completion.
    public static func estimatedSessionCost(window: TimeWindow) -> Double {
        estimatedSuggestionCost()
            + estimatedLessonCost(window: window)
            + estimatedRecallQuestionCost(window: window)
    }

    /// Formatted for display. Sub-cent values show three decimals rather than
    /// rounding to "$0.00", which reads as free.
    public static func formatted(_ dollars: Double) -> String {
        if dollars > 0, dollars < 0.01 {
            return String(format: "$%.3f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }
}
