import XCTest
@testable import SpareCore

final class TimeWindowTests: XCTestCase {

    func testAllFourWindowsInOrder() {
        XCTAssertEqual(TimeWindow.allCases, [.three, .ten, .fifteen, .fortyFive])
    }

    func testMinutes() {
        XCTAssertEqual(TimeWindow.three.minutes, 3)
        XCTAssertEqual(TimeWindow.ten.minutes, 10)
        XCTAssertEqual(TimeWindow.fifteen.minutes, 15)
        XCTAssertEqual(TimeWindow.fortyFive.minutes, 45)
    }

    func testWordBudgetsMatchSpec() {
        XCTAssertEqual(TimeWindow.three.wordBudget, 500...650)
        XCTAssertEqual(TimeWindow.ten.wordBudget, 1600...2000)
        XCTAssertEqual(TimeWindow.fifteen.wordBudget, 2400...3000)
        XCTAssertEqual(TimeWindow.fortyFive.wordBudget, 7000...9000)
    }

    func testFormatsMatchSpec() {
        XCTAssertEqual(TimeWindow.three.format, .oneThing)
        XCTAssertEqual(TimeWindow.ten.format, .explainer)
        XCTAssertEqual(TimeWindow.fifteen.format, .lesson)
        XCTAssertEqual(TimeWindow.fortyFive.format, .miniCourse)
    }

    func testOnlyMiniCourseIsChaptered() {
        XCTAssertFalse(LessonFormat.oneThing.isChaptered)
        XCTAssertFalse(LessonFormat.explainer.isChaptered)
        XCTAssertFalse(LessonFormat.lesson.isChaptered)
        XCTAssertTrue(LessonFormat.miniCourse.isChaptered)
        XCTAssertEqual(LessonFormat.miniCourse.chapterCount, 6)
    }

    func testLabels() {
        XCTAssertEqual(TimeWindow.three.label, "3 min")
        XCTAssertEqual(TimeWindow.fortyFive.label, "45 min")
    }

    /// Budgets are calibrated to roughly 200 wpm minus absorption overhead. The
    /// 3-minute window sits slightly above that (650 words is ~217 wpm) because
    /// a One Thing needs a floor of substance to be worth reading — so this
    /// asserts a sane band rather than a hard 200 ceiling.
    func testBudgetsImplyAPlausibleReadingRate() {
        for window in TimeWindow.allCases {
            let fastest = Double(window.wordBudget.upperBound) / Double(window.minutes)
            let slowest = Double(window.wordBudget.lowerBound) / Double(window.minutes)
            XCTAssertLessThanOrEqual(fastest, 220, "\(window) demands an implausible reading rate")
            XCTAssertGreaterThanOrEqual(slowest, 150, "\(window) wastes the time the reader gave it")
        }
    }

    func testLongerWindowsCarryStrictlyLargerBudgets() {
        let budgets = TimeWindow.allCases.map(\.wordBudget)
        for (shorter, longer) in zip(budgets, budgets.dropFirst()) {
            XCTAssertLessThan(shorter.upperBound, longer.lowerBound)
        }
    }

    func testFreeTierCoversOnlyShortWindows() {
        XCTAssertTrue(TimeWindow.three.isFreeTierEligible)
        XCTAssertTrue(TimeWindow.ten.isFreeTierEligible)
        XCTAssertFalse(TimeWindow.fifteen.isFreeTierEligible)
        XCTAssertFalse(TimeWindow.fortyFive.isFreeTierEligible)
    }

    func testChapterBudgetSumsIntoWholeBudget() {
        let window = TimeWindow.fortyFive
        let chapters = window.format.chapterCount
        let perChapter = window.chapterWordBudget
        XCTAssertLessThanOrEqual(perChapter.upperBound * chapters, window.wordBudget.upperBound)
        // Six chapters at the per-chapter floor must be close to the whole floor.
        XCTAssertGreaterThan(perChapter.lowerBound * chapters, window.wordBudget.lowerBound - 20)
    }

    func testUnchapteredWindowsUseWholeBudgetPerChapter() {
        for window in [TimeWindow.three, .ten, .fifteen] {
            XCTAssertEqual(window.chapterWordBudget, window.wordBudget)
        }
    }

    func testCodableRoundTrip() throws {
        for window in TimeWindow.allCases {
            let data = try JSONEncoder().encode(window)
            XCTAssertEqual(try JSONDecoder().decode(TimeWindow.self, from: data), window)
        }
    }

    func testRawValuesAreStableAcrossReleases() {
        // Persisted in SwiftData; renaming a case would orphan stored rows.
        XCTAssertEqual(TimeWindow.three.rawValue, "three")
        XCTAssertEqual(TimeWindow.ten.rawValue, "ten")
        XCTAssertEqual(TimeWindow.fifteen.rawValue, "fifteen")
        XCTAssertEqual(TimeWindow.fortyFive.rawValue, "fortyFive")
    }
}
