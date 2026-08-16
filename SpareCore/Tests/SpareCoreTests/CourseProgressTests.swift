import XCTest
@testable import SpareCore

final class CourseProgressTests: XCTestCase {

    private let chapters = TimeWindow.thirty.format.chapterCount // 4

    // MARK: - Chapter index

    func testStartOfCourseIsChapterZero() {
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0, chapterCount: chapters), 0)
    }

    func testQuartersMapToChapters() {
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0.10, chapterCount: 4), 0)
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0.25, chapterCount: 4), 1)
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0.40, chapterCount: 4), 1)
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0.75, chapterCount: 4), 3)
    }

    /// The off-by-one that matters: a fully read course is on the last
    /// chapter, not one past the end.
    func testFullyReadClampsToTheLastChapter() {
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 1.0, chapterCount: 4), 3)
    }

    func testOutOfRangeProgressIsClampedBothWays() {
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: -0.5, chapterCount: 4), 0)
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 9, chapterCount: 4), 3)
    }

    func testUnchapteredFormatsAreAlwaysChapterZero() {
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0.9, chapterCount: 1), 0)
    }

    // MARK: - Chapters completed

    /// Distinct from the index on purpose: partway through chapter 2, one
    /// chapter is done and the current one is not.
    func testCompletedCountsWhatIsBehindTheReaderNotWhatTheyAreIn() {
        XCTAssertEqual(CourseProgress.chaptersCompleted(scrollProgress: 0.40, chapterCount: 4), 1)
        XCTAssertEqual(CourseProgress.chapterIndex(scrollProgress: 0.40, chapterCount: 4), 1)
    }

    func testFinishingCompletesEveryChapter() {
        XCTAssertEqual(CourseProgress.chaptersCompleted(scrollProgress: 1.0, chapterCount: 4), 4)
    }

    func testNothingReadCompletesNothing() {
        XCTAssertEqual(CourseProgress.chaptersCompleted(scrollProgress: 0, chapterCount: 4), 0)
    }

    // MARK: - Wording

    func testPositionLabelIsOneBased() {
        XCTAssertEqual(
            CourseProgress.positionLabel(chapterIndex: 1, chapterCount: 4),
            "Chapter 2 of 4"
        )
        XCTAssertEqual(
            CourseProgress.positionLabel(chapterIndex: 0, chapterCount: 4),
            "Chapter 1 of 4"
        )
        XCTAssertEqual(
            CourseProgress.positionLabel(chapterIndex: 3, chapterCount: 4),
            "Chapter 4 of 4"
        )
    }

    func testPositionLabelNeverExceedsTheChapterCount() {
        XCTAssertEqual(
            CourseProgress.positionLabel(chapterIndex: 99, chapterCount: 4),
            "Chapter 4 of 4"
        )
    }

    func testCompletionLabelReadsAsAStoppingPoint() {
        XCTAssertEqual(
            CourseProgress.completionLabel(chaptersCompleted: 2, chapterCount: 4),
            "chapter 2 of 4 done"
        )
    }

    func testCompletionLabelClampsAtBothEnds() {
        XCTAssertEqual(
            CourseProgress.completionLabel(chaptersCompleted: -1, chapterCount: 4),
            "chapter 0 of 4 done"
        )
        XCTAssertEqual(
            CourseProgress.completionLabel(chaptersCompleted: 9, chapterCount: 4),
            "chapter 4 of 4 done"
        )
    }

    // MARK: - Resumability

    func testAPartlyReadCourseIsResumable() {
        XCTAssertTrue(
            CourseProgress.isResumable(window: .thirty, scrollProgress: 0.4, completedAt: nil)
        )
    }

    func testAFinishedCourseIsNotResumable() {
        XCTAssertFalse(
            CourseProgress.isResumable(window: .thirty, scrollProgress: 1.0, completedAt: nil),
            "read to the end"
        )
        XCTAssertFalse(
            CourseProgress.isResumable(window: .thirty, scrollProgress: 0.4, completedAt: .now),
            "explicitly marked complete"
        )
    }

    func testAnUnstartedCourseIsNotResumable() {
        XCTAssertFalse(
            CourseProgress.isResumable(window: .thirty, scrollProgress: 0, completedAt: nil),
            "nothing to resume — this is just starting"
        )
    }

    /// Resuming is a course affordance. A half-read 10-minute explainer is
    /// not offered as "Chapter 2 of 4" on Home.
    func testSingleSittingWindowsAreNeverResumable() {
        for window in [TimeWindow.three, .ten, .fifteen] {
            XCTAssertFalse(
                CourseProgress.isResumable(window: window, scrollProgress: 0.5, completedAt: nil),
                "\(window) is one sitting"
            )
        }
    }
}
