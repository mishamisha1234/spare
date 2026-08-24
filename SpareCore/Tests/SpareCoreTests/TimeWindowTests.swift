import XCTest
@testable import SpareCore

final class TimeWindowTests: XCTestCase {

    /// Ascending, and the order is load-bearing: `allCases` is what Home lays
    /// out and what the batch tool iterates.
    func testAllFiveWindowsInAscendingOrder() {
        XCTAssertEqual(TimeWindow.allCases, [.one, .three, .seven, .fifteen, .thirty])
    }

    func testMinutes() {
        XCTAssertEqual(TimeWindow.one.minutes, 1)
        XCTAssertEqual(TimeWindow.three.minutes, 3)
        XCTAssertEqual(TimeWindow.seven.minutes, 7)
        XCTAssertEqual(TimeWindow.fifteen.minutes, 15)
        XCTAssertEqual(TimeWindow.thirty.minutes, 30)
    }

    func testWordBudgetsMatchSpec() {
        XCTAssertEqual(TimeWindow.one.wordBudget, 180...240)
        XCTAssertEqual(TimeWindow.three.wordBudget, 500...650)
        XCTAssertEqual(TimeWindow.seven.wordBudget, 1100...1400)
        XCTAssertEqual(TimeWindow.fifteen.wordBudget, 2400...3000)
        XCTAssertEqual(TimeWindow.thirty.wordBudget, 6000...6400)
    }

    func testFormatsMatchSpec() {
        // One minute and three minutes are the same shape at different depths.
        XCTAssertEqual(TimeWindow.one.format, .oneThing)
        XCTAssertEqual(TimeWindow.three.format, .oneThing)
        XCTAssertEqual(TimeWindow.seven.format, .explainer)
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
        for window in [TimeWindow.one, .three, .seven, .fifteen] {
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

    /// And the same for the explainer, which was ten minutes and is now seven.
    ///
    /// This is the one the spec asked for by name, because the failure mode has
    /// nearly shipped here before: a removed case decodes to nil, the call
    /// site's `?? .three` turns it into a 3-minute One Thing, and a reader's
    /// saved explainer quietly becomes something else. Nothing crashes and
    /// nothing logs.
    func testLegacyTenRawValueMapsToTheExplainerThatReplacedIt() {
        XCTAssertEqual(TimeWindow.stored(rawValue: "ten"), .seven)
        XCTAssertEqual(TimeWindow.stored(rawValue: "ten")?.format, .explainer,
                       "a migrated explainer must still be an explainer")
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
    /// short windows sit above that because a One Thing needs a floor of
    /// substance to be worth reading — so this asserts a sane band rather than a
    /// hard 200 ceiling.
    ///
    /// The band widens below three minutes rather than being widened for
    /// everyone. The overhead of arriving at a piece and leaving it does not
    /// shrink with the piece: at fifteen minutes it is noise, at one minute it
    /// is most of the difference between 200 words and 240. Holding the
    /// 1-minute window to the same 220 as the 30-minute one would be arithmetic
    /// pretending to be a reading model.
    func testBudgetsImplyAPlausibleReadingRate() {
        for window in TimeWindow.allCases {
            let fastest = Double(window.wordBudget.upperBound) / Double(window.minutes)
            let slowest = Double(window.wordBudget.lowerBound) / Double(window.minutes)
            let ceiling: Double = window.minutes < 3 ? 250 : 220
            XCTAssertLessThanOrEqual(fastest, ceiling, "\(window) demands an implausible reading rate")
            XCTAssertGreaterThanOrEqual(slowest, 150, "\(window) wastes the time the reader gave it")
        }
    }

    func testLongerWindowsCarryStrictlyLargerBudgets() {
        let budgets = TimeWindow.allCases.map(\.wordBudget)
        for (shorter, longer) in zip(budgets, budgets.dropFirst()) {
            XCTAssertLessThan(shorter.upperBound, longer.lowerBound)
        }
    }

    /// Not the two shortest: the 1-minute length is premium, and that is the
    /// point of it. "The shortest one is the paid one" is counterintuitive
    /// enough to make a free reader stop and look.
    func testFreeTierCoversTheTwoMiddleWindows() {
        XCTAssertFalse(TimeWindow.one.isFreeTierEligible)
        XCTAssertTrue(TimeWindow.three.isFreeTierEligible)
        XCTAssertTrue(TimeWindow.seven.isFreeTierEligible)
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
        for window in [TimeWindow.one, .three, .seven, .fifteen] {
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
        XCTAssertEqual(TimeWindow.one.rawValue, "one")
        XCTAssertEqual(TimeWindow.three.rawValue, "three")
        XCTAssertEqual(TimeWindow.seven.rawValue, "seven")
        XCTAssertEqual(TimeWindow.fifteen.rawValue, "fifteen")
        XCTAssertEqual(TimeWindow.thirty.rawValue, "thirty")
    }
}
