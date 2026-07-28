import XCTest
@testable import SpareCore

final class RecallSchedulerTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testIntervalsMatchSpec() {
        XCTAssertEqual(RecallScheduler.intervalDays, [1, 3, 7, 21, 60])
    }

    func testCorrectAdvancesThroughEveryStage() {
        var stage = 0
        for expected in [1, 2, 3, 4] {
            stage = RecallScheduler.nextStage(after: stage, correct: true)
            XCTAssertEqual(stage, expected)
        }
    }

    func testCorrectAtFinalStageStays() {
        XCTAssertEqual(RecallScheduler.nextStage(after: 4, correct: true), 4)
    }

    func testIncorrectGoesBackOneStage() {
        XCTAssertEqual(RecallScheduler.nextStage(after: 3, correct: false), 2)
        XCTAssertEqual(RecallScheduler.nextStage(after: 1, correct: false), 0)
    }

    func testIncorrectAtFirstStageStays() {
        XCTAssertEqual(RecallScheduler.nextStage(after: 0, correct: false), 0)
    }

    func testOutOfRangeStagesClamp() {
        XCTAssertEqual(RecallScheduler.nextStage(after: -5, correct: false), 0)
        XCTAssertEqual(RecallScheduler.nextStage(after: 99, correct: true), 4)
        XCTAssertEqual(RecallScheduler.nextStage(after: 99, correct: false), 3)
    }

    func testDueDateAddsIntervalDays() {
        for (stage, days) in RecallScheduler.intervalDays.enumerated() {
            let due = RecallScheduler.dueDate(forStage: stage, from: now, calendar: calendar)
            XCTAssertEqual(due, calendar.date(byAdding: .day, value: days, to: now))
        }
    }

    func testRescheduleCorrectFromStartIsThreeDaysOut() {
        let result = RecallScheduler.reschedule(stage: 0, correct: true, now: now, calendar: calendar)
        XCTAssertEqual(result.stage, 1)
        XCTAssertEqual(result.dueAt, calendar.date(byAdding: .day, value: 3, to: now))
    }

    func testIncorrectNeverReschedulesSoonerThanOneDay() {
        for stage in 0...4 {
            let result = RecallScheduler.reschedule(stage: stage, correct: false, now: now, calendar: calendar)
            XCTAssertGreaterThanOrEqual(
                result.dueAt.timeIntervalSince(now),
                TimeInterval(23 * 3600),
                "stage \(stage) rescheduled sooner than a day"
            )
        }
    }

    func testFullLifecycle() {
        var stage = 0
        stage = RecallScheduler.nextStage(after: stage, correct: true)   // 1
        stage = RecallScheduler.nextStage(after: stage, correct: true)   // 2
        stage = RecallScheduler.nextStage(after: stage, correct: false)  // 1
        stage = RecallScheduler.nextStage(after: stage, correct: true)   // 2
        XCTAssertEqual(stage, 2)
    }

    // MARK: - Selecting the single question per session

    private struct Item {
        var name: String
        var due: Date
    }

    func testPicksMostOverdueItem() {
        let items = [
            Item(name: "later", due: now.addingTimeInterval(-100)),
            Item(name: "oldest", due: now.addingTimeInterval(-10_000)),
            Item(name: "future", due: now.addingTimeInterval(5_000)),
        ]
        let picked = RecallScheduler.nextDueItem(from: items, now: now, dueAt: \.due)
        XCTAssertEqual(picked?.name, "oldest")
    }

    func testReturnsNilWhenNothingIsDue() {
        let items = [Item(name: "future", due: now.addingTimeInterval(3_600))]
        XCTAssertNil(RecallScheduler.nextDueItem(from: items, now: now, dueAt: \.due))
    }

    func testItemDueExactlyNowCounts() {
        let items = [Item(name: "now", due: now)]
        XCTAssertEqual(RecallScheduler.nextDueItem(from: items, now: now, dueAt: \.due)?.name, "now")
    }
}
