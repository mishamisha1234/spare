import XCTest
@testable import SpareCore

final class TimeWindowTests: XCTestCase {

    func testAllFourWindowsInOrder() {
        XCTAssertEqual(TimeWindow.allCases, [.three, .ten, .fifteen, .thirty])
    }

    func testMinutes() {
        XCTAssertEqual(TimeWindow.three.minutes, 3)
        XCTAssertEqual(TimeWindow.ten.minutes, 10)
        XCTAssertEqual(TimeWindow.fifteen.minutes, 15)
        XCTAssertEqual(TimeWindow.thirty.minutes, 30)
    }

    func testWordBudgetsMatchSpec() {
        XCTAssertEqual(TimeWindow.three.wordBudget, 500...650)
        XCTAssertEqual(TimeWindow.ten.wordBudget, 1600...2000)
        XCTAssertEqual(TimeWindow.fifteen.wordBudget, 2400...3000)
        XCTAssertEqual(TimeWindow.thirty.wordBudget, 5000...6000)
    }

    func testFormatsMatchSpec() {
        XCTAssertEqual(TimeWindow.three.format, .oneThing)
        XCTAssertEqual(TimeWindow.ten.format, .explainer)
        XCTAssertEqual(TimeWindow.fifteen.format, .lesson)
        XCTAssertEqual(TimeWindow.thirty.format, .miniCourse)
    }

    func testOnlyMiniCourseIsChaptered() {
        XCTAssertFalse(LessonFormat.oneThing.isChaptered)
        XCTAssertFalse(LessonFormat.explainer.isChaptered)
        XCTAssertFalse(LessonFormat.lesson.isChaptered)
        XCTAssertTrue(LessonFormat.miniCourse.isChaptered)
        XCTAssertEqual(LessonFormat.miniCourse.chapterCount, 4)
    }

    func testLabels() {
        XCTAssertEqual(TimeWindow.three.label, "3 min")
        XCTAssertEqual(TimeWindow.thirty.label, "30 min")
    }

    // MARK: - Home circle copy

    /// A course is named for what it is, not how long it takes: it isn't one
    /// sitting, so the duration moves to the second line.
    func testCourseCircleIsTitledByWhatItIsNotHowLong() {
        XCTAssertEqual(TimeWindow.thirty.circleTitle, "Course")
        XCTAssertEqual(TimeWindow.thirty.circleSubtitle, "30 min · 4 chapters")
    }

    func testSingleSittingCirclesKeepTheirDurationAndCarryNoSubtitle() {
        for window in [TimeWindow.three, .ten, .fifteen] {
            XCTAssertEqual(window.circleTitle, window.label)
            XCTAssertNil(window.circleSubtitle, "\(window) is one sitting; its title already says so")
        }
    }

    /// The subtitle is derived, not written out — it can't drift from
    /// `chapterCount` the way a hardcoded string would.
    func testCourseSubtitleTracksTheRealChapterCount() {
        let subtitle = TimeWindow.thirty.circleSubtitle ?? ""
        XCTAssertTrue(subtitle.contains("\(TimeWindow.thirty.format.chapterCount) chapters"))
        XCTAssertTrue(subtitle.contains(TimeWindow.thirty.label))
    }

    // MARK: - Stored raw values

    /// Courses used to be 45 minutes. A row written then must not decode into
    /// a 3-minute One Thing via the call site's `?? .three` fallback.
    func testLegacyFortyFiveRawValueMapsToTheCourseThatReplacedIt() {
        XCTAssertEqual(TimeWindow.stored(rawValue: "fortyFive"), .thirty)
    }

    func testStoredDecodesEveryCurrentRawValue() {
        for window in TimeWindow.allCases {
            XCTAssertEqual(TimeWindow.stored(rawValue: window.rawValue), window)
        }
    }

    func testStoredRejectsNonsense() {
        XCTAssertNil(TimeWindow.stored(rawValue: "ninety"))
        XCTAssertNil(TimeWindow.stored(rawValue: ""))
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
        XCTAssertFalse(TimeWindow.thirty.isFreeTierEligible)
    }

    func testChapterBudgetSumsIntoWholeBudget() {
        let window = TimeWindow.thirty
        let chapters = window.format.chapterCount
        let perChapter = window.chapterWordBudget
        XCTAssertLessThanOrEqual(perChapter.upperBound * chapters, window.wordBudget.upperBound)
        // Four chapters at the per-chapter floor must be close to the whole floor.
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
        XCTAssertEqual(TimeWindow.thirty.rawValue, "thirty")
    }
}
