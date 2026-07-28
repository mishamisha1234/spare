import XCTest
@testable import SpareCore

final class PromptsTests: XCTestCase {

    private let profile = ProfileSnapshot(
        interests: ["economic history", "materials science"],
        work: "physiotherapist",
        curiosityGaps: ["how interest rates actually work"],
        complexity: .standard
    )

    // MARK: - Lesson prompt

    func testLessonPromptCarriesWindowMinutesFormatAndBudget() {
        for window in TimeWindow.allCases {
            let prompt = Prompts.lessonSystemPrompt(topic: "Why bridges hum", window: window, profile: profile)
            XCTAssertTrue(prompt.contains("has \(window.minutes) minutes"))
            XCTAssertTrue(prompt.contains(window.format.displayName))
            XCTAssertTrue(prompt.contains("\(window.wordBudget.lowerBound)"))
            XCTAssertTrue(prompt.contains("\(window.wordBudget.upperBound)"))
            XCTAssertTrue(prompt.contains("Why bridges hum"))
        }
    }

    func testLessonPromptInjectsReaderContext() {
        let prompt = Prompts.lessonSystemPrompt(topic: "T", window: .ten, profile: profile)
        XCTAssertTrue(prompt.contains("physiotherapist"))
        XCTAssertTrue(prompt.contains("economic history"))
        XCTAssertTrue(prompt.contains("how interest rates actually work"))
        XCTAssertTrue(prompt.contains("never mention it"))
    }

    func testEmptyProfileFieldsRenderAsUnstatedRatherThanBlank() {
        let prompt = Prompts.lessonSystemPrompt(topic: "T", window: .ten, profile: .empty)
        XCTAssertTrue(prompt.contains("Works in: unstated"))
        XCTAssertTrue(prompt.contains("Interested in: unstated"))
        XCTAssertFalse(prompt.contains("Works in: \n"))
    }

    func testLessonPromptKeepsTheCraftRules() {
        let prompt = Prompts.lessonSystemPrompt(topic: "T", window: .ten, profile: profile)
        for required in [
            "Open with something concrete",
            "Never open with a definition",
            "concrete instance within two sentences",
            "repeat to someone else",
            "Vary sentence length hard",
            "Prose by default",
            "changing how the reader sees",
            "NEVER USE",
            "NEVER DO",
            "FACTUAL DISCIPLINE",
            "Never invent a statistic",
            "Under-budget and tight beats on-budget and thin",
        ] {
            XCTAssertTrue(prompt.contains(required), "lesson prompt lost: \(required)")
        }
    }

    func testLessonPromptForbidsEveryBannedPhrase() {
        let prompt = Prompts.lessonSystemPrompt(topic: "T", window: .ten, profile: profile).lowercased()
        for phrase in ["delve", "moreover", "furthermore", "tapestry", "realm", "game-changer", "let's dive in"] {
            XCTAssertTrue(prompt.contains(phrase), "banned-phrase list lost: \(phrase)")
        }
    }

    func testLessonPromptStatesStructureForTheFormat() {
        XCTAssertTrue(
            Prompts.lessonSystemPrompt(topic: "T", window: .three, profile: profile)
                .contains("No sections")
        )
        XCTAssertTrue(
            Prompts.lessonSystemPrompt(topic: "T", window: .fifteen, profile: profile)
                .contains("worked example")
        )
    }

    func testLessonUserPromptIncludesAngleAndDomainWhenPresent() {
        let topic = TopicSuggestion(title: "Why bridges hum", hook: "Wind makes steel sing.", domainTag: "Engineering")
        let prompt = Prompts.lessonUserPrompt(topic: topic)
        XCTAssertTrue(prompt.contains("Why bridges hum"))
        XCTAssertTrue(prompt.contains("Wind makes steel sing."))
        XCTAssertTrue(prompt.contains("Engineering"))
    }

    func testLessonUserPromptOmitsEmptyFields() {
        let topic = TopicSuggestion(title: "Bare", hook: "", domainTag: "")
        let prompt = Prompts.lessonUserPrompt(topic: topic)
        XCTAssertFalse(prompt.contains("Angle:"))
        XCTAssertFalse(prompt.contains("Domain:"))
    }

    // MARK: - Revision prompt

    func testRevisionPromptListsAllTenChecks() {
        let prompt = Prompts.revisionSystemPrompt(window: .ten)
        for number in 1...10 {
            XCTAssertTrue(prompt.contains("\(number)."), "revision check \(number) missing")
        }
        XCTAssertTrue(prompt.contains("Do not explain your edits"))
        XCTAssertTrue(prompt.contains("1600"))
        XCTAssertTrue(prompt.contains("2000"))
    }

    /// The reader is shown revision output as it streams, so the revision pass
    /// must be told not to reorder anything.
    func testRevisionUserPromptForbidsReordering() {
        let prompt = Prompts.revisionUserPrompt(draftJSON: "{\"title\":\"x\"}")
        XCTAssertTrue(prompt.contains("{\"title\":\"x\"}"))
        XCTAssertTrue(prompt.contains("front to back"))
        XCTAssertTrue(prompt.contains("Do not reorder"))
        XCTAssertTrue(prompt.contains("as it arrives"))
    }

    // MARK: - Chapter prompt

    func testFirstChapterPromptHasNoPriorContext() {
        let prompt = Prompts.chapterSystemPrompt(
            topic: "How planes got safe",
            window: .fortyFive,
            profile: profile,
            chapterNumber: 1,
            chapterCount: 6,
            previousChapterSummaries: []
        )
        XCTAssertTrue(prompt.contains("chapter 1 of 6"))
        XCTAssertTrue(prompt.contains("This is the first chapter"))
        XCTAssertTrue(prompt.contains("reflection prompt"))
    }

    func testLaterChapterPromptCarriesEarlierSummaries() {
        let prompt = Prompts.chapterSystemPrompt(
            topic: "How planes got safe",
            window: .fortyFive,
            profile: profile,
            chapterNumber: 3,
            chapterCount: 6,
            previousChapterSummaries: ["Comet crashes", "Metal fatigue"]
        )
        XCTAssertTrue(prompt.contains("chapter 3 of 6"))
        XCTAssertTrue(prompt.contains("Chapter 1: Comet crashes"))
        XCTAssertTrue(prompt.contains("Chapter 2: Metal fatigue"))
        XCTAssertTrue(prompt.contains("do not repeat them"))
    }

    func testChapterPromptUsesPerChapterBudget() {
        let prompt = Prompts.chapterSystemPrompt(
            topic: "T", window: .fortyFive, profile: profile,
            chapterNumber: 1, chapterCount: 6, previousChapterSummaries: []
        )
        let budget = TimeWindow.fortyFive.chapterWordBudget
        XCTAssertTrue(prompt.contains("\(budget.lowerBound)"))
        XCTAssertTrue(prompt.contains("\(budget.upperBound)"))
        XCTAssertFalse(prompt.contains("7000–9000"), "must not hand a chapter the whole-course budget")
    }

    func testChapterPromptKeepsCraftRules() {
        let prompt = Prompts.chapterSystemPrompt(
            topic: "T", window: .fortyFive, profile: profile,
            chapterNumber: 2, chapterCount: 6, previousChapterSummaries: ["one"]
        )
        XCTAssertTrue(prompt.contains("Open with something concrete"))
        XCTAssertTrue(prompt.contains("NEVER USE"))
        XCTAssertTrue(prompt.contains("FACTUAL DISCIPLINE"))
    }

    // MARK: - Suggestion prompt

    func testSuggestionPromptStatesEveryRule() {
        let prompt = Prompts.suggestionSystemPrompt(window: .three, profile: profile, history: [])
        // Single-line substrings only: a multiline literal strips indentation
        // relative to its closing delimiter, so assertions that span a line
        // break are brittle.
        for required in [
            "exactly 5",
            "at least 3 different domains",
            "Exactly one is a deliberate wildcard",
            "isWildcard: true",
            "curiosity gap",
            "7 words maximum",
            "14 words maximum",
            "without clickbait",
            "instant fail",
            "filter bubble",
        ] {
            XCTAssertTrue(prompt.contains(required), "suggestion prompt lost: \(required)")
        }
    }

    func testSuggestionPromptGivesTheDurationFitExample() {
        let prompt = Prompts.suggestionSystemPrompt(window: .three, profile: profile, history: [])
        XCTAssertTrue(prompt.contains("Ottoman"), "the duration-fit example is load-bearing")
        XCTAssertTrue(prompt.contains("genuinely fit 3 minutes"))
    }

    func testSuggestionPromptListsRecentHistoryForExclusion() {
        let history = [
            LessonDigest(title: "Why bridges hum", topicTag: "Engineering", completedAt: Date()),
            LessonDigest(title: "The florin", topicTag: "History", completedAt: Date().addingTimeInterval(-60)),
        ]
        let prompt = Prompts.suggestionSystemPrompt(window: .ten, profile: profile, history: history)
        XCTAssertTrue(prompt.contains("Why bridges hum [Engineering]"))
        XCTAssertTrue(prompt.contains("The florin [History]"))
        XCTAssertTrue(prompt.contains("do not repeat"))
    }

    func testSuggestionPromptCapsHistoryAtThirtyEntries() {
        let history = (0..<50).map {
            LessonDigest(
                title: "Lesson \($0)",
                topicTag: "Misc",
                completedAt: Date().addingTimeInterval(TimeInterval(-$0 * 60))
            )
        }
        let prompt = Prompts.suggestionSystemPrompt(window: .ten, profile: profile, history: history)
        XCTAssertTrue(prompt.contains("Lesson 0"))
        XCTAssertTrue(prompt.contains("Lesson 29"))
        XCTAssertFalse(prompt.contains("Lesson 30"), "history window is the last 30 lessons")
    }

    func testEmptyHistoryIsStatedExplicitly() {
        let prompt = Prompts.suggestionSystemPrompt(window: .ten, profile: profile, history: [])
        XCTAssertTrue(prompt.contains("(nothing read yet)"))
    }

    // MARK: - Recall prompt

    func testRecallPromptDemandsCentralIdeaAndThreeDistractors() {
        let prompt = Prompts.recallSystemPrompt()
        XCTAssertTrue(prompt.contains("central idea"))
        XCTAssertTrue(prompt.contains("exactly 3 distractors"))
        XCTAssertTrue(prompt.contains("half-read"))
        XCTAssertTrue(prompt.contains("one sentence"))
        XCTAssertTrue(prompt.contains("not about the text"))
    }

    func testRecallUserPromptCarriesTitleClaimAndBody() {
        let lesson = MockProvider.fixtureLesson(
            topic: TopicSuggestion(title: "Why bridges hum", hook: "", domainTag: "Engineering"),
            window: .three
        )
        let prompt = Prompts.recallUserPrompt(lesson: lesson)
        XCTAssertTrue(prompt.contains("Why bridges hum"))
        XCTAssertTrue(prompt.contains(lesson.surprisingClaim))
        XCTAssertTrue(prompt.contains("Millennium Bridge"))
    }

    // MARK: - Go deeper prompt

    func testGoDeeperPromptNamesTheParentAndForbidsRepetition() {
        let prompt = Prompts.goDeeperSystemPrompt(
            window: .ten,
            profile: profile,
            parentTitle: "Why bridges hum",
            angle: DeeperAngle(text: "How a tuned mass damper works")
        )
        XCTAssertTrue(prompt.contains("Why bridges hum"))
        XCTAssertTrue(prompt.contains("How a tuned mass damper works"))
        XCTAssertTrue(prompt.contains("Do not re-explain"))
        XCTAssertTrue(prompt.contains("Go further, not wider"))
    }

    // MARK: - Banned phrase list

    func testBannedPhraseListIsLowercasedAndDeduplicated() {
        let phrases = Prompts.bannedPhrases
        XCTAssertEqual(phrases, phrases.map { $0.lowercased() })
        XCTAssertEqual(Set(phrases).count, phrases.count)
        XCTAssertFalse(phrases.isEmpty)
    }
}
