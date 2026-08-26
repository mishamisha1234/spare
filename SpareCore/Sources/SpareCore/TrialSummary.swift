import Foundation

/// What the free week actually produced, for the day-7 screen.
///
/// The whole selling model turns on this being *true and specific*. The second
/// ask is "is this worth keeping", and the only honest way to put that is with
/// the reader's own numbers. A rounded-up or invented figure here would be the
/// one place in the app where the pitch stopped matching the product.
///
/// Which is why `recallPercent` is optional. A reader who answered no recall
/// questions has no recall accuracy, and the screen omits the line rather than
/// showing "0%" — which reads as a failure — or "100%", which is a lie built
/// out of an empty set.
public struct TrialSummary: Sendable, Equatable {
    /// Lessons completed during the week.
    public var thingsLearned: Int
    /// Consecutive days, ending today or yesterday, on which something was
    /// completed.
    public var streakDays: Int
    /// Whole-percent share of answered recall questions currently sitting on a
    /// correct answer. Nil when nothing has been answered.
    public var recallPercent: Int?

    public init(thingsLearned: Int, streakDays: Int, recallPercent: Int?) {
        self.thingsLearned = thingsLearned
        self.streakDays = streakDays
        self.recallPercent = recallPercent
    }

    public static let empty = TrialSummary(thingsLearned: 0, streakDays: 0, recallPercent: nil)
}

public enum TrialSummaryBuilder {

    /// - Parameters:
    ///   - completionDates: when each completed lesson was finished.
    ///   - recallResults: the current result of every recall item. `unseen`
    ///     entries are excluded rather than counted as wrong — a question
    ///     nobody has been asked yet says nothing about how well they recall.
    ///   - since: the trial's start. Nil counts everything, which is what the
    ///     mid-trial nudge wants.
    public static func make(
        completionDates: [Date],
        recallResults: [RecallResult],
        since: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> TrialSummary {
        let inWindow = completionDates.filter { date in
            guard let since else { return date <= now }
            return date >= since && date <= now
        }

        return TrialSummary(
            thingsLearned: inWindow.count,
            streakDays: streak(completionDates: completionDates, now: now, calendar: calendar),
            recallPercent: recallPercent(recallResults)
        )
    }

    /// Consecutive days with at least one completion, counted backwards.
    ///
    /// Starts from today if something was completed today, and from yesterday
    /// otherwise. Not starting from yesterday would report a broken streak to
    /// somebody who simply has not opened the app yet this morning — and the
    /// day-7 screen is the last place to tell a reader they failed at
    /// something.
    ///
    /// Counted over *every* completion rather than only the trial's, because a
    /// streak is a fact about a habit and does not restart because a billing
    /// state changed.
    public static func streak(
        completionDates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let days = Set(completionDates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }

        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Share of *answered* questions currently on a correct answer.
    ///
    /// Rounded to nearest rather than down, unlike the pricing claims: this is
    /// a report about the reader, not a promise about what they will be
    /// charged, and rounding 82.4% down to 82 is right where rounding a saving
    /// down is a safeguard.
    public static func recallPercent(_ results: [RecallResult]) -> Int? {
        let answered = results.filter { $0 != .unseen }
        guard !answered.isEmpty else { return nil }
        let correct = answered.filter { $0 == .correct }.count
        return Int((Double(correct) / Double(answered.count) * 100).rounded())
    }
}
