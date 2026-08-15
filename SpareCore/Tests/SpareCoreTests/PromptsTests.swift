import XCTest
@testable import SpareCore

/// These test the *structure* of the prompts — that the craft rules survive,
/// that per-call detail stays out of the cached prefix, and that no
/// placeholder ships unrendered. They deliberately avoid asserting on exact
/// wording beyond load-bearing phrases, because the wording is being revised
/// separately and shouldn't have to drag a test suite along with it.
final class PromptsTests: XCTestCase {

    private let profile = ProfileSnapshot(
        interests: ["economic history", "materials science"],
        work: "physiotherapist",
        curiosityGaps: ["how interest rates actually work"],
        complexity: .standard
    )

    private let topic = TopicSuggestion(
        title: "Why bridges hum", hook: "Wind makes steel sing.", domainTag: "Engineering"
    )

    // MARK: - Cacheability of the stable prompts

    /// The whole point of splitting system from task: the system block is
    /// byte-identical on every call, so it can be cached. Any per-lesson
    /// detail leaking into it silently destroys that.
    func testStableSystemPromptsContainNoPlaceholders() {
        for (name, prompt) in Prompts.allSystemPrompts {
            XCTAssertEqual(
                PromptTemplate.unresolvedPlaceholders(in: prompt), [],
                "\(name) system prompt still has placeholders — it cannot be cached"
            )
        }
    }

    func testEditorialPromptIsIdenticalAcrossCalls() {
        // Trivially true for a constant, which is exactly the property that
        // makes it cacheable — this guards against someone turning it into a
        // computed property that interpolates.
        XCTAssertEqual(Prompts.editorialSystemPrompt, Prompts.editorialSystemPrompt)
        XCTAssertFalse(Prompts.editorialSystemPrompt.contains("{{"))
    }

    func testEditorialPromptIsLongEnoughToBeWorthCaching() {
        // Prompt caching has a minimum cacheable prefix; a prompt below it
        // silently won't cache. Rough proxy: characters / 3.6 ~= tokens.
        let approximateTokens = Prompts.editorialSystemPrompt.count / 4
        XCTAssertGreaterThan(
            approximateTokens, 512,
            "editorial prompt may be below the minimum cacheable prefix"
        )
    }

    func testEditorialPromptKeepsTheCraftRules() {
        let prompt = Prompts.editorialSystemPrompt
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
            XCTAssertTrue(prompt.contains(required), "editorial prompt lost: \(required)")
        }
    }

    func testEditorialPromptNamesEveryHardBannedPhrase() {
        let prompt = Prompts.editorialSystemPrompt.lowercased()
        for phrase in ["delve", "moreover", "furthermore", "tapestry", "game-changer"] {
            XCTAssertTrue(prompt.contains(phrase), "hard-banned phrase list lost: \(phrase)")
        }
    }

    /// The advisory words are ordinary nouns/verbs a genuine topic can need
    /// (harness, landscape, ...) — they must never appear in the draft pass's
    /// absolute NEVER USE list, only as a judgment call in the revision pass.
    func testEditorialPromptNeverAbsolutelyBansAnAdvisoryWord() {
        let neverUseSection = Prompts.editorialSystemPrompt
            .components(separatedBy: "NEVER USE").last!
            .components(separatedBy: "NEVER DO").first!
            .lowercased()
        for word in Prompts.advisoryBannedPhrases {
            XCTAssertFalse(
                neverUseSection.contains(word.lowercased()),
                "\"\(word)\" is advisory-only but appears in the absolute NEVER USE list"
            )
        }
    }

    func testFormattingSectionStatesTheMarkdownRules() {
        // Source-wrapped, not model-wrapped: the multiline literal soft-wraps
        // at the file's line width like every other paragraph in this file,
        // so a phrase can straddle a newline that reads as a plain space to
        // anyone (or anything) reading the rendered prompt. Collapse before
        // matching so the test tracks meaning, not incidental line breaks.
        let prompt = Prompts.editorialSystemPrompt.replacingOccurrences(of: "\n", with: " ")
        for required in [
            "FORMATTING",
            "\"## \" headings",
            "written as statements rather than labels",
            "The 3-minute format has no headings at all",
            "No bold in body text",
            "No horizontal rules",
            "No headings above ##",
        ] {
            XCTAssertTrue(prompt.contains(required), "formatting section lost: \(required)")
        }
    }

    func testRevisionPromptListsAllTenChecksAndForbidsReordering() {
        let prompt = Prompts.revisionSystemPrompt
        for number in 1...10 {
            XCTAssertTrue(prompt.contains("\(number)."), "revision check \(number) missing")
        }
        XCTAssertTrue(prompt.contains("Do not explain your edits"))
        XCTAssertTrue(prompt.contains("front to back"))
        XCTAssertTrue(prompt.contains("Do not reorder"))
    }

    /// Both lists must reach the revision pass, and be visibly distinguished:
    /// the hard list says remove, the advisory list says reconsider. Checks
    /// one canonical form per phrase, not every spelling variant in the
    /// array — those variants exist only for the mechanical substring match,
    /// same as `hardBannedPhrases` already mixed "game-changer"/"game
    /// changer" before this split.
    func testRevisionPromptCarriesBothBannedListsWithDifferentInstructions() {
        let prompt = Prompts.revisionSystemPrompt.lowercased()
        XCTAssertTrue(prompt.contains("remove entirely"))
        XCTAssertTrue(prompt.contains("reconsider, do not remove automatically"))
        for word in ["delve", "moreover", "furthermore", "tapestry", "game-changer"] {
            XCTAssertTrue(prompt.contains(word), "revision prompt lost hard-banned: \(word)")
        }
        for word in Prompts.advisoryBannedPhrases {
            XCTAssertTrue(prompt.contains(word.lowercased()), "revision prompt lost advisory: \(word)")
        }
    }

    func testSuggestionPromptStatesEveryRule() {
        let prompt = Prompts.suggestionSystemPrompt
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
            "Ottoman",
        ] {
            XCTAssertTrue(prompt.contains(required), "suggestion prompt lost: \(required)")
        }
    }

    func testRecallPromptDemandsCentralIdeaAndThreeDistractors() {
        let prompt = Prompts.recallSystemPrompt
        XCTAssertTrue(prompt.contains("central idea"))
        XCTAssertTrue(prompt.contains("exactly 3 distractors"))
        XCTAssertTrue(prompt.contains("half-read"))
        XCTAssertTrue(prompt.contains("not about the text"))
    }

    func testOutlinePromptDemandsAnglesAndBuildingChapters() {
        let prompt = Prompts.outlineSystemPrompt
        XCTAssertTrue(prompt.contains("Exactly 3"))
        XCTAssertTrue(prompt.contains("counterargument"))
        XCTAssertTrue(prompt.contains("build"))
        XCTAssertTrue(prompt.contains("no numbering"))
    }

    // MARK: - Task prompts carry the per-call detail

    func testLessonTaskPromptCarriesWindowFormatAndBudget() {
        for window in TimeWindow.allCases {
            let prompt = Prompts.lessonTaskPrompt(topic: topic, window: window, profile: profile)
            XCTAssertTrue(prompt.contains("\(window.minutes) minutes"))
            XCTAssertTrue(prompt.contains(window.format.displayName))
            XCTAssertTrue(prompt.contains("\(window.wordBudget.lowerBound)"))
            XCTAssertTrue(prompt.contains("\(window.wordBudget.upperBound)"))
            XCTAssertTrue(prompt.contains("Why bridges hum"))
        }
    }

    func testLessonTaskPromptInjectsReaderContext() {
        let prompt = Prompts.lessonTaskPrompt(topic: topic, window: .ten, profile: profile)
        XCTAssertTrue(prompt.contains("physiotherapist"))
        XCTAssertTrue(prompt.contains("economic history"))
        XCTAssertTrue(prompt.contains("how interest rates actually work"))
    }

    func testEmptyProfileFieldsRenderAsUnstated() {
        let prompt = Prompts.lessonTaskPrompt(topic: topic, window: .ten, profile: .empty)
        XCTAssertTrue(prompt.contains("Works in: unstated"))
        XCTAssertTrue(prompt.contains("Interested in: unstated"))
    }

    func testLessonTaskPromptOmitsAngleWhenThereIsNoHook() {
        let bare = TopicSuggestion(title: "Bare", hook: "", domainTag: "D")
        let prompt = Prompts.lessonTaskPrompt(topic: bare, window: .ten, profile: profile)
        XCTAssertFalse(prompt.contains("Angle to take:"))
    }

    func testChapterTaskPromptUsesPerChapterBudgetNotTheWholeCourse() {
        let prompt = Prompts.chapterTaskPrompt(
            topic: topic, window: .fortyFive, profile: profile,
            chapterNumber: 1, heading: "The day it happened", previousHeadings: []
        )
        let chapterBudget = TimeWindow.fortyFive.chapterWordBudget
        XCTAssertTrue(prompt.contains("\(chapterBudget.lowerBound)"))
        XCTAssertTrue(prompt.contains("\(chapterBudget.upperBound)"))
        XCTAssertFalse(prompt.contains("7000–9000"), "a chapter must not get the whole-course budget")
        XCTAssertTrue(prompt.contains("chapter 1 of 6"))
        XCTAssertTrue(prompt.contains("reflection prompt"))
    }

    func testFirstChapterHasNoPriorContext() {
        let prompt = Prompts.chapterTaskPrompt(
            topic: topic, window: .fortyFive, profile: profile,
            chapterNumber: 1, heading: "H", previousHeadings: []
        )
        XCTAssertTrue(prompt.contains(Prompts.firstChapterContext))
    }

    func testLaterChapterCarriesEarlierHeadings() {
        let prompt = Prompts.chapterTaskPrompt(
            topic: topic, window: .fortyFive, profile: profile,
            chapterNumber: 3, heading: "Third", previousHeadings: ["Comet crashes", "Metal fatigue"]
        )
        XCTAssertTrue(prompt.contains("Chapter 1: Comet crashes"))
        XCTAssertTrue(prompt.contains("Chapter 2: Metal fatigue"))
        XCTAssertTrue(prompt.contains("do not repeat them"))
    }

    func testSuggestionTaskPromptListsHistoryAndCapsItAtThirty() {
        let history = (0..<50).map {
            LessonDigest(
                title: "Lesson \($0)", topicTag: "Misc",
                completedAt: Date().addingTimeInterval(TimeInterval(-$0 * 60))
            )
        }
        let prompt = Prompts.suggestionTaskPrompt(window: .ten, profile: profile, history: history)
        XCTAssertTrue(prompt.contains("Lesson 0"))
        XCTAssertTrue(prompt.contains("Lesson 29"))
        XCTAssertFalse(prompt.contains("Lesson 30"), "history window is the last 30 lessons")
    }

    func testEmptyHistoryIsStatedExplicitly() {
        let prompt = Prompts.suggestionTaskPrompt(window: .ten, profile: profile, history: [])
        XCTAssertTrue(prompt.contains(Prompts.noHistoryPlaceholder))
    }

    func testRecallTaskPromptCarriesTitleClaimAndBody() {
        let lesson = MockProvider.fixtureLesson(topic: topic, window: .three)
        let prompt = Prompts.recallTaskPrompt(lesson: lesson)
        XCTAssertTrue(prompt.contains(lesson.title))
        XCTAssertTrue(prompt.contains(lesson.surprisingClaim))
        XCTAssertTrue(prompt.contains("Millennium Bridge"))
    }

    func testGoDeeperTaskPromptNamesParentAndForbidsRepetition() {
        let prompt = Prompts.goDeeperTaskPrompt(
            window: .ten, profile: profile, parentTitle: "Why bridges hum",
            angle: DeeperAngle(text: "How a tuned mass damper works")
        )
        XCTAssertTrue(prompt.contains("Why bridges hum"))
        XCTAssertTrue(prompt.contains("How a tuned mass damper works"))
        XCTAssertTrue(prompt.contains("Do not re-explain"))
        XCTAssertTrue(prompt.contains("Go further, not wider"))
    }

    func testRevisionTaskPromptCarriesBudgetAndDraft() {
        let prompt = Prompts.revisionTaskPrompt(window: .ten, draftJSON: #"{"title":"x"}"#)
        XCTAssertTrue(prompt.contains("1600"))
        XCTAssertTrue(prompt.contains(#"{"title":"x"}"#))
    }

    // MARK: - Placeholder hygiene

    /// A renamed or misspelled placeholder would otherwise ship as literal
    /// `{{work}}` text inside a prompt sent to the model.
    func testNoRenderedPromptLeaksAPlaceholder() {
        let lesson = MockProvider.fixtureLesson(topic: topic, window: .three)
        let rendered: [String: String] = [
            "lesson": Prompts.lessonTaskPrompt(topic: topic, window: .ten, profile: profile),
            "lessonNoHook": Prompts.lessonTaskPrompt(
                topic: TopicSuggestion(title: "T", hook: "", domainTag: "D"),
                window: .three, profile: .empty
            ),
            "revision": Prompts.revisionTaskPrompt(window: .ten, draftJSON: "{}"),
            "outline": Prompts.outlineTaskPrompt(topic: topic, window: .fortyFive, profile: profile),
            "chapterFirst": Prompts.chapterTaskPrompt(
                topic: topic, window: .fortyFive, profile: profile,
                chapterNumber: 1, heading: "H", previousHeadings: []
            ),
            "chapterLater": Prompts.chapterTaskPrompt(
                topic: topic, window: .fortyFive, profile: profile,
                chapterNumber: 4, heading: "H", previousHeadings: ["a", "b", "c"]
            ),
            "suggestion": Prompts.suggestionTaskPrompt(
                window: .ten, profile: profile, history: []
            ),
            "recall": Prompts.recallTaskPrompt(lesson: lesson),
            "goDeeper": Prompts.goDeeperTaskPrompt(
                window: .ten, profile: profile, parentTitle: "P", angle: DeeperAngle(text: "A")
            ),
        ]

        for (name, prompt) in rendered {
            XCTAssertEqual(
                PromptTemplate.unresolvedPlaceholders(in: prompt), [],
                "\(name) shipped an unrendered placeholder"
            )
        }
    }

    func testEveryTaskTemplateDeclaresAtLeastOnePlaceholder() {
        for (name, template) in Prompts.allTaskTemplates {
            XCTAssertFalse(
                PromptTemplate.placeholders(in: template).isEmpty,
                "\(name) is a task template with no placeholders — should it be a system prompt?"
            )
        }
    }

    func testBannedPhraseListsAreLowercasedDeduplicatedAndDisjoint() {
        for phrases in [Prompts.hardBannedPhrases, Prompts.advisoryBannedPhrases] {
            XCTAssertEqual(phrases, phrases.map { $0.lowercased() })
            XCTAssertEqual(Set(phrases).count, phrases.count)
            XCTAssertFalse(phrases.isEmpty)
        }
        XCTAssertTrue(
            Set(Prompts.hardBannedPhrases).isDisjoint(with: Prompts.advisoryBannedPhrases),
            "a word can't be both a mechanical fail and a revision-only judgment call"
        )
    }

    // MARK: - Template renderer

    func testRendererSubstitutesEveryOccurrence() {
        let output = PromptTemplate.render("{{a}} and {{a}} then {{b}}", ["a": "X", "b": "Y"])
        XCTAssertEqual(output, "X and X then Y")
    }

    func testRendererLeavesUnknownTokensForTheHygieneTestToCatch() {
        let output = PromptTemplate.render("{{known}} {{missing}}", ["known": "K"])
        XCTAssertEqual(PromptTemplate.unresolvedPlaceholders(in: output), ["missing"])
    }

    func testPlaceholderScannerHandlesTextWithNoTokens() {
        XCTAssertEqual(PromptTemplate.unresolvedPlaceholders(in: "plain text {{"), [])
    }
}
