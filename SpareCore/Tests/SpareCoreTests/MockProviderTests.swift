import XCTest
@testable import SpareCore

final class MockProviderTests: XCTestCase {

    private let provider = MockProvider(simulateLatency: false)
    private let profile = ProfileSnapshot.empty

    private func topic(for window: TimeWindow) -> TopicSuggestion {
        MockProvider.fixtureSuggestions(for: window)[0]
    }

    // MARK: - Suggestions

    func testReturnsExactlyFiveSuggestionsForEveryWindow() async throws {
        for window in TimeWindow.allCases {
            let suggestions = try await provider.suggestTopics(window: window, profile: profile, history: [])
            XCTAssertEqual(suggestions.count, 5, "\(window) should offer exactly 5 topics")
        }
    }

    func testSuggestionsSpanAtLeastThreeDomains() async throws {
        for window in TimeWindow.allCases {
            let suggestions = try await provider.suggestTopics(window: window, profile: profile, history: [])
            XCTAssertGreaterThanOrEqual(Set(suggestions.map(\.domainTag)).count, 3)
        }
    }

    func testExactlyOneWildcardPerSet() async throws {
        for window in TimeWindow.allCases {
            let suggestions = try await provider.suggestTopics(window: window, profile: profile, history: [])
            XCTAssertEqual(suggestions.filter(\.isWildcard).count, 1)
        }
    }

    func testSuggestionsHaveUniqueIdentities() async throws {
        let suggestions = try await provider.suggestTopics(window: .seven, profile: profile, history: [])
        XCTAssertEqual(Set(suggestions.map(\.id)).count, suggestions.count)
    }

    // MARK: - Lessons

    func testLessonBodyLandsInsideWordBudgetForEveryWindow() async throws {
        for window in TimeWindow.allCases {
            let lesson = try await provider.generateLesson(
                topic: topic(for: window), window: window, profile: profile
            )
            XCTAssertTrue(
                window.wordBudget.contains(lesson.wordCount),
                "\(window): \(lesson.wordCount) words outside \(window.wordBudget)"
            )
        }
    }

    func testLessonCarriesExactlyThreeDeeperAngles() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .seven), window: .seven, profile: profile)
        XCTAssertEqual(lesson.deeperAngles.count, 3)
    }

    func testLessonMetadataIsPopulated() async throws {
        let source = topic(for: .seven)
        let lesson = try await provider.generateLesson(topic: source, window: .seven, profile: profile)
        XCTAssertEqual(lesson.title, source.title)
        XCTAssertEqual(lesson.domainTag, source.domainTag)
        XCTAssertFalse(lesson.subtitle.isEmpty)
        XCTAssertFalse(lesson.surprisingClaim.isEmpty)
        XCTAssertEqual(lesson.metadata.title, source.title)
    }

    func testMiniCourseChaptersAreAllNumberedInOrder() async throws {
        let lesson = try await provider.generateLesson(
            topic: topic(for: .thirty), window: .thirty, profile: profile
        )
        for chapter in 1...TimeWindow.thirty.format.chapterCount {
            XCTAssertTrue(
                lesson.bodyMarkdown.contains("## Chapter \(chapter):"),
                "missing chapter \(chapter)"
            )
        }
    }

    func testMiniCourseChaptersEachEndWithAReflectionPrompt() {
        let bodies = MockProvider.fixtureChapterBodies(topic: topic(for: .thirty), window: .thirty)
        XCTAssertEqual(bodies.count, TimeWindow.thirty.format.chapterCount)
        for body in bodies {
            XCTAssertTrue(body.hasSuffix("*"), "chapter should close with an italic reflection prompt")
        }
    }

    func testEachMiniCourseChapterRespectsItsChapterBudget() {
        let bodies = MockProvider.fixtureChapterBodies(topic: topic(for: .thirty), window: .thirty)
        for (index, body) in bodies.enumerated() {
            XCTAssertTrue(
                TimeWindow.thirty.chapterWordBudget.contains(body.lessonWordCount),
                "chapter \(index + 1): \(body.lessonWordCount) words outside \(TimeWindow.thirty.chapterWordBudget)"
            )
        }
    }

    func testOneThingHasNoSectionHeadings() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        XCTAssertFalse(lesson.bodyMarkdown.contains("## "), "the 3-minute One Thing must have no sections")
    }

    func testSectionedFormatsHaveHeadings() async throws {
        for window in [TimeWindow.seven, .fifteen] {
            let lesson = try await provider.generateLesson(topic: topic(for: window), window: window, profile: profile)
            XCTAssertTrue(lesson.bodyMarkdown.contains("## "), "\(window) should be sectioned")
        }
    }

    func testSingleChapterWindowsProduceOneBody() {
        for window in [TimeWindow.three, .seven, .fifteen] {
            XCTAssertEqual(MockProvider.fixtureChapterBodies(topic: topic(for: window), window: window).count, 1)
        }
    }

    func testFixturesAreDeterministic() async throws {
        let first = try await provider.generateLesson(topic: topic(for: .seven), window: .seven, profile: profile)
        let second = try await provider.generateLesson(topic: topic(for: .seven), window: .seven, profile: profile)
        XCTAssertEqual(first, second)
    }

    // MARK: - Streaming

    func testStreamOrdersDraftBeforeRevisionForEveryChapter() async throws {
        var draftFinishedChapters: Set<Int> = []
        var revisedStartedChapters: Set<Int> = []
        var sawMetadata = false
        var finished: Lesson?

        for try await event in provider.streamLesson(
            topic: topic(for: .thirty), window: .thirty, profile: profile
        ) {
            switch event {
            case .metadata:
                XCTAssertFalse(sawMetadata, "metadata must arrive exactly once")
                XCTAssertTrue(revisedStartedChapters.isEmpty, "metadata must precede content")
                sawMetadata = true
            case .draftDelta(let chapter, let text):
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(
                    revisedStartedChapters.contains(chapter),
                    "chapter \(chapter) drafted after its revision began"
                )
            case .draftChapterFinished(let chapter):
                draftFinishedChapters.insert(chapter)
            case .revisedDelta(let chapter, _):
                XCTAssertTrue(
                    draftFinishedChapters.contains(chapter),
                    "chapter \(chapter) revised before its draft finished"
                )
                revisedStartedChapters.insert(chapter)
            case .revisedChapterFinished:
                break
            case .revisionRestarted(let chapter):
                XCTFail("the mock has no word floor to miss; chapter \(chapter) was withdrawn")
            case .finished(let lesson):
                finished = lesson
            }
        }

        XCTAssertTrue(sawMetadata)
        XCTAssertEqual(draftFinishedChapters, Set(0..<TimeWindow.thirty.format.chapterCount))
        XCTAssertEqual(revisedStartedChapters, Set(0..<TimeWindow.thirty.format.chapterCount))
        XCTAssertNotNil(finished)
    }

    func testRevisedDeltasReassembleIntoTheFinalBody() async throws {
        var assembled: [Int: String] = [:]
        var finished: Lesson?

        for try await event in provider.streamLesson(
            topic: topic(for: .fifteen), window: .fifteen, profile: profile
        ) {
            if case .revisedDelta(let chapter, let text) = event {
                assembled[chapter, default: ""] += text
            }
            if case .finished(let lesson) = event {
                finished = lesson
            }
        }

        let lesson = try XCTUnwrap(finished)
        let joined = assembled.keys.sorted().compactMap { assembled[$0] }.joined(separator: "\n\n")
        XCTAssertEqual(joined, lesson.bodyMarkdown)
    }

    func testFinishedEventIsLast() async throws {
        var eventsAfterFinished = 0
        var sawFinished = false
        for try await event in provider.streamLesson(topic: topic(for: .three), window: .three, profile: profile) {
            if sawFinished { eventsAfterFinished += 1 }
            if case .finished = event { sawFinished = true }
        }
        XCTAssertTrue(sawFinished)
        XCTAssertEqual(eventsAfterFinished, 0)
    }

    func testCancellingTheStreamStopsIt() async throws {
        // Everything the Task closure touches is hoisted into a Sendable local:
        // XCTestCase is not Sendable, so capturing `self` is a Swift 6 error.
        let streamProvider = MockProvider(simulateLatency: true, chunkDelayMilliseconds: 30)
        let source = MockProvider.fixtureSuggestions(for: .thirty)[0]
        let snapshot = ProfileSnapshot.empty

        let task = Task { () -> Int in
            var count = 0
            for try await _ in streamProvider.streamLesson(
                topic: source, window: .thirty, profile: snapshot
            ) {
                count += 1
                if count == 3 { break }
            }
            return count
        }
        let received = try await task.value
        XCTAssertEqual(received, 3)
    }

    // MARK: - Recall

    func testRecallQuestionShape() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        let question = try await provider.generateRecallQuestion(for: lesson)
        XCTAssertEqual(question.distractors.count, 3)
        XCTAssertFalse(question.question.isEmpty)
        XCTAssertFalse(question.answer.isEmpty)
        XCTAssertFalse(question.explanation.isEmpty)
        XCTAssertFalse(question.distractors.contains(question.answer))
    }

    func testRecallOptionsAreStableForASeedAndContainTheAnswer() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        let question = try await provider.generateRecallQuestion(for: lesson)

        let first = question.options(seed: 12_345)
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(Set(first), Set([question.answer] + question.distractors))
        XCTAssertEqual(first, question.options(seed: 12_345), "same seed must give the same order")
    }

    func testRecallOptionOrderVariesAcrossSeeds() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        let question = try await provider.generateRecallQuestion(for: lesson)
        let orders = Set((1...40).map { question.options(seed: UInt64($0)).joined(separator: "|") })
        XCTAssertGreaterThan(orders.count, 1, "answer position must not be fixed")
    }

    func testZeroSeedIsHandled() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        let question = try await provider.generateRecallQuestion(for: lesson)
        XCTAssertEqual(Set(question.options(seed: 0)).count, 4)
    }

    // MARK: - Post-lesson test

    /// The count is a function of the length, and the server rejects an
    /// uploaded test that does not match it exactly — so a fixture that always
    /// returned three would be a fixture that could never be attached.
    func testPostLessonTestReturnsAsManyQuestionsAsTheLengthCallsFor() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        for window in TimeWindow.allCases {
            let questions = try await provider.generatePostLessonTest(for: lesson, window: window)
            XCTAssertEqual(questions.count, window.testQuestionCount, "\(window)")
            for question in questions {
                XCTAssertEqual(question.distractors.count, 3)
                XCTAssertFalse(question.question.isEmpty)
                XCTAssertFalse(question.answer.isEmpty)
                XCTAssertFalse(question.distractors.contains(question.answer))
            }
        }
    }

    func testPostLessonTestQuestionsAreNotAllIdentical() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .three), window: .three, profile: profile)
        // The course, because ten is where a fixture that pads with repeats
        // would give itself away.
        let questions = try await provider.generatePostLessonTest(for: lesson, window: .thirty)
        XCTAssertEqual(Set(questions.map(\.question)).count, questions.count, "each question should ask something different")
    }

    // MARK: - Go deeper

    func testGoDeeperStaysInBudgetAndReferencesTheParent() async throws {
        let lesson = try await provider.generateLesson(topic: topic(for: .seven), window: .seven, profile: profile)
        let deeper = try await provider.goDeeper(
            from: lesson,
            angle: DeeperAngle(text: lesson.deeperAngles[0]),
            window: .seven,
            profile: profile
        )
        XCTAssertTrue(TimeWindow.seven.wordBudget.contains(deeper.wordCount))
        XCTAssertTrue(deeper.subtitle.contains(lesson.title))
        XCTAssertEqual(deeper.title, lesson.deeperAngles[0])
    }

    // MARK: - DTO decoding

    func testTopicSuggestionDecodesWithoutAnID() throws {
        let json = Data(#"{"title":"Why bridges hum","hook":"Wind makes steel sing.","domainTag":"Engineering"}"#.utf8)
        let suggestion = try JSONDecoder().decode(TopicSuggestion.self, from: json)
        XCTAssertEqual(suggestion.title, "Why bridges hum")
        XCTAssertFalse(suggestion.isWildcard)
    }

    func testTopicSuggestionRoundTripPreservesID() throws {
        let original = TopicSuggestion(title: "T", hook: "H", domainTag: "D", isWildcard: true)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(TopicSuggestion.self, from: data), original)
    }

    func testLessonRoundTrip() throws {
        let lesson = MockProvider.fixtureLesson(topic: topic(for: .three), window: .three)
        let data = try JSONEncoder().encode(lesson)
        XCTAssertEqual(try JSONDecoder().decode(Lesson.self, from: data), lesson)
    }

    func testSuggestionsResponseEnvelopeDecodes() throws {
        let json = Data("""
        {"suggestions":[
          {"title":"A","hook":"h","domainTag":"D","isWildcard":false},
          {"title":"B","hook":"h","domainTag":"E","isWildcard":true}
        ]}
        """.utf8)
        let response = try JSONDecoder().decode(TopicSuggestionsResponse.self, from: json)
        XCTAssertEqual(response.suggestions.count, 2)
        XCTAssertTrue(response.suggestions[1].isWildcard)
    }

    func testChapterResponseAppliesItsNumber() {
        let chapter = ChapterResponse(heading: "The day it happened", bodyMarkdown: "Text.")
        XCTAssertEqual(chapter.markdown(chapterNumber: 3), "## Chapter 3: The day it happened\n\nText.")
    }
}
