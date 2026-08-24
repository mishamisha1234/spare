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

    // MARK: - Chapter boundaries in rendered blocks

    private func courseBlocks(chapters: Int) -> [LessonBlock] {
        var markdown: [String] = []
        for chapter in 1...chapters {
            markdown.append("## Chapter \(chapter): Heading \(chapter)")
            markdown.append("Body of chapter \(chapter).")
            markdown.append("*A reflection for chapter \(chapter).*")
        }
        return LessonBlockParser.parse(markdown.joined(separator: "\n\n"))
    }

    func testEachReflectionClosesTheNextChapterInOrder() {
        let blocks = courseBlocks(chapters: 4)
        let ends = CourseProgress.chapterEndsByBlockID(blocks: blocks)

        XCTAssertEqual(ends.count, 4, "one chapter end per reflection prompt")
        let reflections = blocks.filter { $0.kind == .reflection }
        for (offset, block) in reflections.enumerated() {
            XCTAssertEqual(ends[block.id], offset + 1)
        }
    }

    /// The lookup has to stay right mid-stream, when only some chapters have
    /// arrived — a partially generated course still shows honest progress.
    func testChapterEndsAreCorrectWhileStillStreaming() {
        let ends = CourseProgress.chapterEndsByBlockID(blocks: courseBlocks(chapters: 2))
        XCTAssertEqual(ends.count, 2)
        XCTAssertEqual(Set(ends.values), [1, 2])
    }

    func testProseOnlyContentHasNoChapterEnds() {
        let blocks = LessonBlockParser.parse("Just one idea.\n\nNo headings, no reflection.")
        XCTAssertTrue(CourseProgress.chapterEndsByBlockID(blocks: blocks).isEmpty)
    }

    func testOpeningBlockOfEachChapterIsItsHeading() {
        let blocks = courseBlocks(chapters: 4)
        let headings = blocks.filter { $0.kind == .heading }
        for index in 0..<4 {
            XCTAssertEqual(CourseProgress.blockID(openingChapter: index, blocks: blocks), headings[index].id)
        }
    }

    func testResumingPastTheGeneratedChaptersFindsNothingToScrollTo() {
        let blocks = courseBlocks(chapters: 2)
        XCTAssertNil(CourseProgress.blockID(openingChapter: 3, blocks: blocks))
        XCTAssertNil(CourseProgress.blockID(openingChapter: -1, blocks: blocks))
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
        for window in [TimeWindow.three, .seven, .fifteen] {
            XCTAssertFalse(
                CourseProgress.isResumable(window: window, scrollProgress: 0.5, completedAt: nil),
                "\(window) is one sitting"
            )
        }
    }
}
