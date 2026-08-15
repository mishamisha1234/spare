import XCTest
@testable import SpareCore

final class PointsLedgerTests: XCTestCase {

    private func event(
        _ kind: PointEventKind,
        amount: Int,
        daysAgo: Int = 0,
        sourceID: String = "lesson-1"
    ) -> PointEvent {
        PointEvent(
            occurredAt: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
            kind: kind,
            amount: amount,
            sourceID: sourceID
        )
    }

    // MARK: - Award amounts

    func testLessonCompletionPointsAscendWithWindowLength() {
        XCTAssertEqual(Points.forCompleting(.three), 10)
        XCTAssertEqual(Points.forCompleting(.ten), 20)
        XCTAssertEqual(Points.forCompleting(.fifteen), 30)
        XCTAssertEqual(Points.forCompleting(.fortyFive), 60)
    }

    func testCorrectRecallIsFlatRegardlessOfSourceLength() {
        // The whole design point: retention is worth the same no matter what
        // it's retention *of*.
        XCTAssertEqual(Points.forCorrectRecall, 30)
        XCTAssertGreaterThanOrEqual(Points.forCorrectRecall, Points.forCompleting(.fortyFive) / 2)
    }

    func testIncorrectRecallEarnsNothing() {
        XCTAssertEqual(Points.forIncorrectRecall, 0)
    }

    // MARK: - Ledger

    func testInMemoryLedgerIsAppendOnlyAndOrderPreserving() async {
        let ledger = InMemoryPointsLedger()
        let first = event(.lessonCompleted, amount: 10)
        let second = event(.recallCorrect, amount: 30)
        await ledger.record(first)
        await ledger.record(second)
        let events = await ledger.events
        XCTAssertEqual(events, [first, second])
    }

    func testNoopLedgerDiscardsSilently() async {
        let ledger = NoopPointsLedger()
        await ledger.record(event(.lessonCompleted, amount: 10))
        // No crash, nothing to assert beyond "this compiles and returns".
    }

    // MARK: - Summary

    func testTotalSumsAllAmountsIncludingZeros() {
        let events = [
            event(.lessonCompleted, amount: 10),
            event(.recallCorrect, amount: 30),
            event(.recallIncorrect, amount: 0),
        ]
        XCTAssertEqual(PointsSummary.total(events), 40)
    }

    func testByKindGroupsCorrectly() {
        let events = [
            event(.lessonCompleted, amount: 10),
            event(.lessonCompleted, amount: 20),
            event(.recallCorrect, amount: 30),
        ]
        let totals = PointsSummary.byKind(events)
        XCTAssertEqual(totals[.lessonCompleted], 30)
        XCTAssertEqual(totals[.recallCorrect], 30)
        XCTAssertNil(totals[.postLessonTestCorrect])
    }

    func testRecallAttemptsExcludesLessonCompletion() {
        let events = [
            event(.lessonCompleted, amount: 10),
            event(.recallCorrect, amount: 30),
            event(.recallIncorrect, amount: 0),
            event(.postLessonTestCorrect, amount: 30),
            event(.postLessonTestIncorrect, amount: 0),
        ]
        XCTAssertEqual(PointsSummary.recallAttempts(events).count, 4)
    }

    func testRecallAccuracyIsNilWithNoAttempts() {
        XCTAssertNil(PointsSummary.recallAccuracy([event(.lessonCompleted, amount: 10)]))
    }

    func testRecallAccuracyCountsBothQuestionSources() {
        let events = [
            event(.recallCorrect, amount: 30),
            event(.recallIncorrect, amount: 0),
            event(.postLessonTestCorrect, amount: 30),
            event(.postLessonTestCorrect, amount: 30),
        ]
        // 3 correct out of 4 attempts.
        XCTAssertEqual(PointsSummary.recallAccuracy(events), 0.75)
    }

    func testActiveDayCountCountsDistinctCalendarDaysNotConsecutiveStreak() {
        let events = [
            event(.lessonCompleted, amount: 10, daysAgo: 0),
            event(.lessonCompleted, amount: 10, daysAgo: 0),
            event(.lessonCompleted, amount: 10, daysAgo: 5),
            event(.lessonCompleted, amount: 10, daysAgo: 10),
        ]
        // Two same-day events collapse to one active day; the gap between
        // day -5 and day -10 does not disqualify either from counting.
        XCTAssertEqual(PointsSummary.activeDayCount(events), 3)
    }
}
