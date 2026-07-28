import Foundation

public enum RecallResult: String, Codable, Sendable {
    case unseen
    case correct
    case incorrect
}

/// Pure spaced-repetition scheduling.
///
/// Stages index into `intervalDays` = [1, 3, 7, 21, 60].
/// Correct → advance one stage (capped at the last).
/// Incorrect → back one stage (floored at the first, so minimum 1 day).
public enum RecallScheduler {
    public static let intervalDays: [Int] = [1, 3, 7, 21, 60]

    public static var lastStage: Int { intervalDays.count - 1 }

    public static func nextStage(after stage: Int, correct: Bool) -> Int {
        let clamped = clampStage(stage)
        return correct
            ? min(clamped + 1, lastStage)
            : max(clamped - 1, 0)
    }

    public static func dueDate(
        forStage stage: Int,
        from now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let days = intervalDays[clampStage(stage)]
        return calendar.date(byAdding: .day, value: days, to: now)
            ?? now.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// Apply an answer: returns the new stage and the new due date.
    public static func reschedule(
        stage: Int,
        correct: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> (stage: Int, dueAt: Date) {
        let newStage = nextStage(after: stage, correct: correct)
        return (newStage, dueDate(forStage: newStage, from: now, calendar: calendar))
    }

    /// Never more than one question per session: the single most overdue item.
    public static func nextDueItem<Item>(
        from items: [Item],
        now: Date,
        dueAt: (Item) -> Date
    ) -> Item? {
        items
            .filter { dueAt($0) <= now }
            .min { dueAt($0) < dueAt($1) }
    }

    public static func clampStage(_ stage: Int) -> Int {
        min(max(stage, 0), lastStage)
    }
}
