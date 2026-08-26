import XCTest
@testable import SpareCore

/// The day-7 screen's numbers and the sentences built from them.
///
/// These matter more than most copy tests. The second ask is "is this worth
/// keeping", and the only honest way to put that question is with the reader's
/// own figures — so a padded or invented number here is the one place the
/// pitch would stop matching the product.
final class TrialSummaryTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ count: Double) -> Date {
        now.addingTimeInterval(-count * 86_400)
    }

    // MARK: - Counting the week

    func testCountsOnlyLessonsFinishedDuringTheTrial() {
        let summary = TrialSummaryBuilder.make(
            completionDates: [daysAgo(30), daysAgo(6), daysAgo(2), daysAgo(0.5)],
            recallResults: [],
            since: daysAgo(7),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(summary.thingsLearned, 3, "the 30-day-old lesson predates the trial")
    }

    func testCountsEverythingWhenThereIsNoStart() {
        let summary = TrialSummaryBuilder.make(
            completionDates: [daysAgo(30), daysAgo(2)],
            recallResults: [],
            since: nil,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(summary.thingsLearned, 2)
    }

    // MARK: - Streak

    func testStreakCountsConsecutiveDaysBackFromToday() {
        let dates = [daysAgo(0.2), daysAgo(1.2), daysAgo(2.2), daysAgo(5)]
        XCTAssertEqual(
            TrialSummaryBuilder.streak(completionDates: dates, now: now, calendar: calendar),
            3
        )
    }

    /// Somebody who has not opened the app yet this morning still has their
    /// streak. Reporting a broken one would be telling a reader they failed at
    /// something, on the screen where that costs the most.
    func testStreakSurvivesADayNotYetStarted() {
        let dates = [daysAgo(1.2), daysAgo(2.2)]
        XCTAssertEqual(
            TrialSummaryBuilder.streak(completionDates: dates, now: now, calendar: calendar),
            2
        )
    }

    func testStreakIsZeroOnceTwoDaysHavePassed() {
        let dates = [daysAgo(2.2), daysAgo(3.2)]
        XCTAssertEqual(
            TrialSummaryBuilder.streak(completionDates: dates, now: now, calendar: calendar),
            0
        )
    }

    func testSeveralLessonsInOneDayAreOneDayOfStreak() {
        // All three inside today: `now` is 08:00 UTC, so 0.6 of a day back
        // would land on yesterday evening and make this a two-day streak.
        let dates = [daysAgo(0.05), daysAgo(0.1), daysAgo(0.2)]
        XCTAssertEqual(
            TrialSummaryBuilder.streak(completionDates: dates, now: now, calendar: calendar),
            1
        )
    }

    func testNoCompletionsIsNoStreak() {
        XCTAssertEqual(TrialSummaryBuilder.streak(completionDates: [], now: now, calendar: calendar), 0)
    }

    // MARK: - Recall

    func testRecallIgnoresQuestionsNobodyHasBeenAsked() {
        // 5 correct, 1 incorrect, and three never shown. 5/6 = 83.3% -> 83.
        let results: [RecallResult] =
            [.correct, .correct, .correct, .correct, .correct, .incorrect, .unseen, .unseen, .unseen]
        XCTAssertEqual(TrialSummaryBuilder.recallPercent(results), 83)
    }

    /// Nil, not zero. A reader who has answered nothing has no accuracy, and
    /// "0% recall" on the day-7 screen reads as a verdict on them.
    func testNoAnswersMeansNoRecallFigureAtAll() {
        XCTAssertNil(TrialSummaryBuilder.recallPercent([]))
        XCTAssertNil(TrialSummaryBuilder.recallPercent([.unseen, .unseen]))
    }

    func testAllCorrectIsAHundred() {
        XCTAssertEqual(TrialSummaryBuilder.recallPercent([.correct, .correct]), 100)
    }

    // MARK: - The sentences

    func testTheSummaryLineReadsAsTheSpecWroteIt() {
        let summary = TrialSummary(thingsLearned: 17, streakDays: 6, recallPercent: 82)
        XCTAssertEqual(
            TrialCopy.summaryLine(summary),
            "17 things you now know. 6-day streak. 82% recall."
        )
    }

    /// Every clause that has nothing true to say is dropped rather than
    /// padded. A "1-day streak" is not a streak, and a recall figure built
    /// from no answers is not a figure.
    func testEmptyClausesAreOmittedRatherThanFaked() {
        let bare = TrialCopy.summaryLine(
            TrialSummary(thingsLearned: 2, streakDays: 1, recallPercent: nil)
        )
        XCTAssertEqual(bare, "2 things you now know.")
        XCTAssertFalse(bare.contains("streak"))
        XCTAssertFalse(bare.contains("%"))
    }

    func testSingularsAreNotPluralised() {
        XCTAssertEqual(
            TrialCopy.summaryLine(TrialSummary(thingsLearned: 1, streakDays: 0, recallPercent: nil)),
            "1 thing you now know."
        )
        XCTAssertEqual(TrialCopy.nudge(daysRemaining: 1, thingsLearned: 1), "1 day left of Premium. You've learned 1 thing.")
    }

    func testTheNudgeIsAProgressReportAndNotAPitch() {
        let nudge = TrialCopy.nudge(daysRemaining: 3, thingsLearned: 9).lowercased()
        XCTAssertEqual(TrialCopy.nudge(daysRemaining: 3, thingsLearned: 9),
                       "3 days left of Premium. You've learned 9 things.")
        for pitch in ["$", "upgrade", "subscribe", "only", "don't miss", "hurry", "offer"] {
            XCTAssertFalse(nudge.contains(pitch), "the nudge is selling: \(nudge)")
        }
    }

    // MARK: - The offer

    /// The cap is disclosed in the offer itself, not discovered later. This is
    /// the assertion the whole App Review argument rests on.
    func testTheOfferStatesBothCaps() {
        XCTAssertTrue(TrialCopy.offerBody.contains("\(TrialLimits.lessons) lessons"), TrialCopy.offerBody)
        XCTAssertTrue(TrialCopy.offerBody.contains("\(TrialLimits.days) days"), TrialCopy.offerBody)
        XCTAssertTrue(
            TrialCopy.offerCourseNote.contains("\(TrialLimits.courses)"),
            TrialCopy.offerCourseNote
        )
    }

    func testTheOfferSaysThereIsNoCard() {
        XCTAssertTrue(TrialCopy.offerBody.lowercased().contains("no card"), TrialCopy.offerBody)
    }

    /// It is a grant, not a question. A reader who has just declined to pay
    /// must not be asked a second time in the same breath.
    func testTheOfferDoesNotAskForAnything() {
        let body = (TrialCopy.offerHeadline + " " + TrialCopy.offerBody).lowercased()
        XCTAssertFalse(body.contains("?"), body)
        for ask in ["would you", "sign up", "start your trial", "try premium", "$"] {
            XCTAssertFalse(body.contains(ask), "the offer is asking rather than giving: \(body)")
        }
    }

    /// The numbers come from the limits, so a cap change cannot leave the
    /// sentence describing the old one.
    func testTheOfferFollowsTheLimits() {
        XCTAssertTrue(TrialCopy.offerBody.contains("\(TrialLimits.lessons)"))
        XCTAssertFalse(
            TrialCopy.offerBody.contains("unlimited"),
            "the trial is capped and the offer must not imply otherwise"
        )
    }

    func testTheDayShownSummaryPromisesTheLibraryStays() {
        let note = TrialCopy.summaryFreeTierNote.lowercased()
        XCTAssertTrue(note.contains("library stays"), note)
        XCTAssertTrue(note.contains("recall keeps running"), note)
        XCTAssertTrue(note.contains("one lesson a day"), note)
    }
}
