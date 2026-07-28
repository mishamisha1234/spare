import Foundation

/// Declared on `StringProtocol` rather than `String` so it also applies to the
/// `Substring` values that `split` produces.
extension StringProtocol {
    /// Whitespace-separated word count; the unit all budget and pacing math
    /// is expressed in.
    public var lessonWordCount: Int {
        split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Word count of the first `limit` characters, used for cheap incremental
    /// counting while streaming.
    public func lessonWordCount(upTo limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        guard limit < count else { return lessonWordCount }
        let endIndex = index(startIndex, offsetBy: limit)
        return self[startIndex..<endIndex].split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Reading-time and pacing math. Pure, no dependencies.
public enum ReadingTime {
    /// Words per minute assumed for a lay reader on unfamiliar material.
    /// Deliberately below the 200 wpm used to size budgets: budgets are a
    /// generation constraint, this is a display estimate.
    public static let wordsPerMinute = 180

    /// Rounded-up minutes to read `wordCount` words. Always at least 1 for
    /// non-empty text.
    public static func minutes(forWordCount wordCount: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        return max(1, Int((Double(wordCount) / Double(wordsPerMinute)).rounded(.up)))
    }

    /// Minutes remaining given how far through the text the reader is.
    /// `progress` is clamped to 0...1.
    public static func minutesRemaining(totalWordCount: Int, progress: Double) -> Int {
        let clamped = min(max(progress, 0), 1)
        let remaining = Int((Double(totalWordCount) * (1 - clamped)).rounded())
        return minutes(forWordCount: remaining)
    }

    /// Reader's word offset implied by a scroll progress fraction.
    public static func wordOffset(totalWordCount: Int, progress: Double) -> Int {
        let clamped = min(max(progress, 0), 1)
        return Int((Double(totalWordCount) * clamped).rounded(.down))
    }

    /// Whether a generated body respects its window's budget. Under-budget and
    /// tight beats on-budget and padded, so only the ceiling is enforced;
    /// the floor is reported separately by `budgetAssessment`.
    public static func isWithinBudget(wordCount: Int, window: TimeWindow) -> Bool {
        window.wordBudget.contains(wordCount)
    }

    public enum BudgetAssessment: Equatable, Sendable {
        case onTarget
        /// Acceptable: tight beats padded.
        case under(by: Int)
        /// Not acceptable: the reader will run out of time.
        case over(by: Int)
    }

    public static func budgetAssessment(wordCount: Int, window: TimeWindow) -> BudgetAssessment {
        let budget = window.wordBudget
        if wordCount < budget.lowerBound {
            return .under(by: budget.lowerBound - wordCount)
        }
        if wordCount > budget.upperBound {
            return .over(by: wordCount - budget.upperBound)
        }
        return .onTarget
    }
}
