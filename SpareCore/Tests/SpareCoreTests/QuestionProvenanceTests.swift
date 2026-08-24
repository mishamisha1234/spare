import XCTest
@testable import SpareCore

/// Questions must be about the lesson they were generated for.
///
/// A design review found the post-lesson test for "How GPS corrects for
/// relativity" serving four options about the Millennium Bridge. The cause
/// was `MockProvider.fixtureLesson` hardcoding one `surprisingClaim`
/// regardless of topic — and that claim is exactly what both the recall
/// question and the post-lesson test use as the correct answer. Every
/// lesson's quiz was therefore about a footbridge.
///
/// Nothing failed, because every individual piece was self-consistent.
/// These tests compare *across* lessons, which is the only way that class of
/// bug is visible.
final class QuestionProvenanceTests: XCTestCase {

    private let provider = MockProvider(simulateLatency: false)

    private let gps = TopicSuggestion(
        title: "How GPS corrects for relativity",
        hook: "Satellite clocks run fast.",
        domainTag: "Physics"
    )
    private let bridges = TopicSuggestion(
        title: "Why bridges hum",
        hook: "Wind makes steel sing.",
        domainTag: "Engineering"
    )

    private func lesson(_ topic: TopicSuggestion) -> Lesson {
        MockProvider.fixtureLesson(topic: topic, window: .seven)
    }

    // MARK: - The claim the quiz is built on

    func testTwoLessonsDoNotShareASurprisingClaim() {
        XCTAssertNotEqual(
            lesson(gps).surprisingClaim,
            lesson(bridges).surprisingClaim,
            "every lesson had the same claim, so every quiz had the same answer"
        )
    }

    func testTheClaimNamesItsOwnTopic() {
        XCTAssertTrue(
            lesson(gps).surprisingClaim.lowercased().contains("gps"),
            "the claim doesn't mention the lesson it belongs to"
        )
        XCTAssertTrue(lesson(bridges).surprisingClaim.lowercased().contains("bridges"))
    }

    // MARK: - Post-lesson test

    func testPostLessonTestAnswersBelongToTheirOwnLesson() async throws {
        let gpsQuestions = try await provider.generatePostLessonTest(for: lesson(gps), window: .seven)
        let bridgeQuestions = try await provider.generatePostLessonTest(for: lesson(bridges), window: .seven)

        XCTAssertFalse(gpsQuestions.isEmpty)
        XCTAssertEqual(gpsQuestions.count, bridgeQuestions.count)

        for (gpsQuestion, bridgeQuestion) in zip(gpsQuestions, bridgeQuestions) {
            XCTAssertNotEqual(
                gpsQuestion.answer, bridgeQuestion.answer,
                "two different lessons produced the same correct answer"
            )
        }
    }

    /// The exact failure from the review: a bridge answer under a GPS title.
    func testNoQuestionForOneLessonMentionsTheOtherLessonsSubject() async throws {
        let gpsQuestions = try await provider.generatePostLessonTest(for: lesson(gps), window: .seven)
        for question in gpsQuestions {
            let text = ([question.question, question.answer, question.explanation]
                + question.distractors).joined(separator: " ").lowercased()
            for foreign in ["bridge", "millennium", "footbridge", "pedestrian"] {
                XCTAssertFalse(
                    text.contains(foreign),
                    "a GPS question mentions \"\(foreign)\""
                )
            }
        }
    }

    func testDailyRecallQuestionIsAlsoKeyedToItsLesson() async throws {
        let gpsRecall = try await provider.generateRecallQuestion(for: lesson(gps))
        let bridgeRecall = try await provider.generateRecallQuestion(for: lesson(bridges))
        XCTAssertNotEqual(gpsRecall.answer, bridgeRecall.answer)
        XCTAssertTrue(gpsRecall.question.contains("How GPS corrects for relativity"))
    }

    /// The body is what the question is supposedly drawn from, so it has to
    /// be about the same subject too.
    func testLessonBodyIsAboutItsOwnTopic() {
        let body = lesson(gps).bodyMarkdown.lowercased()
        XCTAssertTrue(body.contains("gps"), "the body never mentions its own subject")
        XCTAssertFalse(body.contains("millennium bridge"), "the body is about a different lesson")
    }

    // MARK: - Stable option order

    /// The same question must present its options in the same order every
    /// time; a remembered position that moves is worse than no order at all.
    func testOptionOrderIsStableAcrossCalls() async throws {
        let question = try await provider.generateRecallQuestion(for: lesson(gps))
        let first = question.stableOptions
        for _ in 0..<20 {
            XCTAssertEqual(question.stableOptions, first)
        }
    }

    func testDifferentQuestionsGetDifferentOrders() async throws {
        // Not a correctness requirement so much as a sanity check that the
        // seed actually depends on the text rather than being a constant.
        let seeds = Set(
            ["a", "b", "c", "d", "e"].map { RecallQuestion.stableSeed(for: $0) }
        )
        XCTAssertEqual(seeds.count, 5, "the seed ignores its input")
    }

    func testStableSeedIsNeverZero() {
        // The shuffle treats 0 as unseeded and would fall back to a constant.
        XCTAssertNotEqual(RecallQuestion.stableSeed(for: ""), 0)
    }

    func testOptionsAlwaysContainTheAnswerAndEveryDistractor() async throws {
        let question = try await provider.generateRecallQuestion(for: lesson(gps))
        let options = question.stableOptions
        XCTAssertEqual(options.count, 4)
        XCTAssertTrue(options.contains(question.answer))
        for distractor in question.distractors {
            XCTAssertTrue(options.contains(distractor))
        }
    }
}
