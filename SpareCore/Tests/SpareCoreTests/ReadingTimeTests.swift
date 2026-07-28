import XCTest
@testable import SpareCore

final class ReadingTimeTests: XCTestCase {

    func testWordCount() {
        XCTAssertEqual("one two three".lessonWordCount, 3)
        XCTAssertEqual("".lessonWordCount, 0)
        XCTAssertEqual("   ".lessonWordCount, 0)
        XCTAssertEqual("  spaced   out\nwords\n\nhere  ".lessonWordCount, 4)
    }

    func testWordCountUpToCharacterLimit() {
        let text = "alpha beta gamma delta"
        XCTAssertEqual(text.lessonWordCount(upTo: 0), 0)
        XCTAssertEqual(text.lessonWordCount(upTo: 5), 1)
        XCTAssertEqual(text.lessonWordCount(upTo: 10), 2)
        XCTAssertEqual(text.lessonWordCount(upTo: 9_999), 4)
    }

    func testMinutesRoundsUpAndFloorsAtOne() {
        XCTAssertEqual(ReadingTime.minutes(forWordCount: 0), 0)
        XCTAssertEqual(ReadingTime.minutes(forWordCount: 1), 1)
        XCTAssertEqual(ReadingTime.minutes(forWordCount: 180), 1)
        XCTAssertEqual(ReadingTime.minutes(forWordCount: 181), 2)
        XCTAssertEqual(ReadingTime.minutes(forWordCount: 540), 3)
    }

    func testMinutesRemainingShrinksWithProgress() {
        let total = 1_800
        XCTAssertEqual(ReadingTime.minutesRemaining(totalWordCount: total, progress: 0), 10)
        XCTAssertEqual(ReadingTime.minutesRemaining(totalWordCount: total, progress: 0.5), 5)
        XCTAssertEqual(ReadingTime.minutesRemaining(totalWordCount: total, progress: 1), 0)
    }

    func testMinutesRemainingClampsOutOfRangeProgress() {
        XCTAssertEqual(ReadingTime.minutesRemaining(totalWordCount: 900, progress: -3), 5)
        XCTAssertEqual(ReadingTime.minutesRemaining(totalWordCount: 900, progress: 4), 0)
    }

    func testWordOffsetFromProgress() {
        XCTAssertEqual(ReadingTime.wordOffset(totalWordCount: 1_000, progress: 0), 0)
        XCTAssertEqual(ReadingTime.wordOffset(totalWordCount: 1_000, progress: 0.25), 250)
        XCTAssertEqual(ReadingTime.wordOffset(totalWordCount: 1_000, progress: 1), 1_000)
        XCTAssertEqual(ReadingTime.wordOffset(totalWordCount: 1_000, progress: 1.9), 1_000)
        XCTAssertEqual(ReadingTime.wordOffset(totalWordCount: 1_000, progress: -0.5), 0)
    }

    func testEstimatedMinutesTrackStatedWindowLength() {
        // A body at the middle of its budget should read in roughly the
        // advertised time. Allow generous slack: the display rate is
        // deliberately slower than the rate budgets were sized at.
        for window in TimeWindow.allCases {
            let midpoint = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
            let estimate = ReadingTime.minutes(forWordCount: midpoint)
            XCTAssertGreaterThanOrEqual(estimate, window.minutes - 2, "\(window) reads too fast")
            XCTAssertLessThanOrEqual(estimate, window.minutes + 6, "\(window) reads too slow")
        }
    }

    func testBudgetMembership() {
        XCTAssertTrue(ReadingTime.isWithinBudget(wordCount: 600, window: .three))
        XCTAssertFalse(ReadingTime.isWithinBudget(wordCount: 900, window: .three))
        XCTAssertFalse(ReadingTime.isWithinBudget(wordCount: 100, window: .three))
    }

    func testBudgetAssessment() {
        XCTAssertEqual(ReadingTime.budgetAssessment(wordCount: 600, window: .three), .onTarget)
        XCTAssertEqual(ReadingTime.budgetAssessment(wordCount: 400, window: .three), .under(by: 100))
        XCTAssertEqual(ReadingTime.budgetAssessment(wordCount: 700, window: .three), .over(by: 50))
    }

    func testBudgetBoundariesAreInclusive() {
        XCTAssertEqual(ReadingTime.budgetAssessment(wordCount: 500, window: .three), .onTarget)
        XCTAssertEqual(ReadingTime.budgetAssessment(wordCount: 650, window: .three), .onTarget)
    }
}
