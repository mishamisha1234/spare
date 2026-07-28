import XCTest
@testable import SpareCore

final class LessonQualityCheckTests: XCTestCase {

    private func lesson(
        body: String,
        angles: [String] = ["a", "b", "c"]
    ) -> Lesson {
        Lesson(
            title: "T", subtitle: "S", domainTag: "D",
            bodyMarkdown: body,
            surprisingClaim: "C",
            deeperAngles: angles
        )
    }

    private func filler(words: Int) -> String {
        Array(repeating: "word", count: words).joined(separator: " ") + "."
    }

    func testCleanLessonProducesNoFindings() {
        let body = MockProvider.fixtureLesson(
            topic: TopicSuggestion(title: "Why bridges hum", hook: "", domainTag: "Engineering"),
            window: .three
        )
        XCTAssertEqual(LessonQualityCheck.findings(for: body, window: .three), [])
    }

    func testEveryMockFixtureIsCleanForItsWindow() {
        for window in TimeWindow.allCases {
            let fixture = MockProvider.fixtureLesson(
                topic: MockProvider.fixtureSuggestions(for: window)[0],
                window: window
            )
            let findings = LessonQualityCheck.findings(for: fixture, window: window)
            XCTAssertEqual(findings, [], "\(window): \(findings.map(\.description))")
        }
    }

    // MARK: - Banned phrases

    func testDetectsBannedPhrase() {
        let body = "On June 10, 2000 the bridge swayed. Moreover, it kept swaying. " + filler(words: 520)
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertTrue(findings.contains(.bannedPhrase("moreover")))
    }

    func testBannedPhraseMatchIsCaseInsensitive() {
        let body = "On June 10, 2000 the bridge swayed. Let's dive in. " + filler(words: 520)
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: body), window: .three)
                .contains(.bannedPhrase("let's dive in"))
        )
    }

    func testNounLeverageIsAllowedButVerbFormIsNot() {
        let allowed = "In 1998 the fund ran 30 to 1 leverage and failed. " + filler(words: 520)
        XCTAssertFalse(
            LessonQualityCheck.findings(for: lesson(body: allowed), window: .three)
                .contains(.bannedPhrase("leverage"))
        )

        let banned = "In 1998 the fund began leveraging its position. " + filler(words: 520)
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: banned), window: .three)
                .contains(.bannedPhrase("leverage"))
        )
    }

    // MARK: - Budget

    func testFlagsOverBudget() {
        let findings = LessonQualityCheck.findings(for: lesson(body: filler(words: 900)), window: .three)
        XCTAssertTrue(findings.contains { finding in
            if case .overBudget = finding { return true }
            return false
        })
    }

    func testTightIsAcceptableButThinIsFlagged() {
        // 480 words against a 500 floor: tight, allowed.
        let tight = LessonQualityCheck.findings(for: lesson(body: filler(words: 480)), window: .three)
        XCTAssertFalse(tight.contains { finding in
            if case .wellUnderBudget = finding { return true }
            return false
        })

        // 200 words against a 500 floor: thin.
        let thin = LessonQualityCheck.findings(for: lesson(body: filler(words: 200)), window: .three)
        XCTAssertTrue(thin.contains { finding in
            if case .wellUnderBudget = finding { return true }
            return false
        })
    }

    // MARK: - Openings

    func testFlagsDefinitionOpening() {
        let body = "Resonance is a phenomenon where systems oscillate. " + filler(words: 520)
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: body), window: .three)
                .contains { finding in
                    if case .opensWithDefinition = finding { return true }
                    return false
                }
        )
    }

    func testConcreteOpeningWithANumberIsAccepted() {
        let body = "On June 10, 2000 the Millennium Bridge is a thing that swayed. " + filler(words: 520)
        XCTAssertFalse(
            LessonQualityCheck.findings(for: lesson(body: body), window: .three)
                .contains { finding in
                    if case .opensWithDefinition = finding { return true }
                    return false
                },
            "a date anchors the opening even if the sentence contains 'is a'"
        )
    }

    func testSkipsHeadingsWhenFindingTheOpeningSentence() {
        let body = "## A heading\n\nResonance is a phenomenon of systems. " + filler(words: 1_700)
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: body), window: .ten)
                .contains { finding in
                    if case .opensWithDefinition = finding { return true }
                    return false
                }
        )
    }

    // MARK: - Emoji

    func testFlagsEmoji() {
        let body = "On June 10, 2000 the bridge swayed \u{1F309}. " + filler(words: 520)
        XCTAssertTrue(LessonQualityCheck.findings(for: lesson(body: body), window: .three).contains(.containsEmoji))
    }

    func testDoesNotFlagDashesQuotesOrAccents() {
        let body = "On June 10, 2000 — a Saturday — the \u{201C}wobbly bridge\u{201D} closed in Genève. "
            + filler(words: 520)
        XCTAssertFalse(LessonQualityCheck.findings(for: lesson(body: body), window: .three).contains(.containsEmoji))
    }

    // MARK: - Structure

    func testFlagsWrongDeeperAngleCount() {
        let body = MockProvider.fixtureChapterBodies(
            topic: TopicSuggestion(title: "t", hook: "", domainTag: "d"), window: .three
        )[0]
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: body, angles: ["only one"]), window: .three)
                .contains(.wrongDeeperAngleCount(1))
        )
    }

    func testFlagsClosingThatRestatesTheOpening() {
        let opening = "On June 10, 2000 the Millennium Bridge opened across the Thames and immediately began swaying sideways under synchronised pedestrian footfalls."
        let middle = filler(words: 400)
        let closing = "The Millennium Bridge opened across the Thames on June 10, 2000 and immediately began swaying sideways under synchronised pedestrian footfalls."
        let body = [opening, middle, closing].joined(separator: "\n\n")
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: body), window: .three)
                .contains(.closingRestatesOpening)
        )
    }

    func testDoesNotFlagADistinctClosing() {
        let opening = "On June 10, 2000 the Millennium Bridge opened across the Thames and began swaying."
        let middle = filler(words: 400)
        let closing = "Next time a footbridge feels alive beneath your shoes, a hidden mass is spending your energy so the steel does not have to."
        let body = [opening, middle, closing].joined(separator: "\n\n")
        XCTAssertFalse(
            LessonQualityCheck.findings(for: lesson(body: body), window: .three)
                .contains(.closingRestatesOpening)
        )
    }

    // MARK: - Rhythm

    func testFlagsUniformSentenceLengths() {
        // Every sentence exactly 20 words.
        let sentence = Array(repeating: "word", count: 20).joined(separator: " ") + "."
        let body = Array(repeating: sentence, count: 28).joined(separator: " ")
        XCTAssertTrue(
            LessonQualityCheck.findings(for: lesson(body: body), window: .three)
                .contains { finding in
                    if case .uniformSentenceLength = finding { return true }
                    return false
                }
        )
    }

    func testVariedRhythmIsNotFlagged() {
        let fixture = MockProvider.fixtureLesson(
            topic: TopicSuggestion(title: "t", hook: "", domainTag: "d"), window: .fifteen
        )
        XCTAssertFalse(
            LessonQualityCheck.findings(for: fixture, window: .fifteen)
                .contains { finding in
                    if case .uniformSentenceLength = finding { return true }
                    return false
                }
        )
    }

    func testFindingsAreDescribable() {
        for finding in [
            LessonQualityCheck.Finding.bannedPhrase("delve"),
            .overBudget(words: 900, limit: 650),
            .wellUnderBudget(words: 100, floor: 500),
            .opensWithDefinition("X is a thing"),
            .containsEmoji,
            .closingRestatesOpening,
            .wrongDeeperAngleCount(2),
            .uniformSentenceLength(mean: 20),
        ] {
            XCTAssertFalse(finding.description.isEmpty)
        }
    }
}
