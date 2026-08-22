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

    // MARK: - Closing construction

    /// The tic the first batch produced twelve times out of twelve, eight of
    /// them with this exact opener.
    func testFlagsTheClosingConstructionTheBatchKeptReachingFor() {
        let body = "In 1954 the ward ran out of the drug and the patient died.\n\n"
            + filler(words: 480)
            + "\n\nNext time you pass one of those towers, the question is what it cost."
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertTrue(findings.contains(.bannedClosingConstruction("next time")))
    }

    func testFlagsSoTheNextTimeAsItsOwnPhraseNotTheShorterOneInsideIt() {
        let body = "In 1954 the ward ran out of the drug and the patient died.\n\n"
            + filler(words: 480)
            + "\n\nSo the next time a lamp flickers, you know what is behind it."
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertTrue(findings.contains(.bannedClosingConstruction("so the next time")))
    }

    /// "Look again at" is banned in the closing position and nowhere else — a
    /// perfectly good mid-argument sentence must survive.
    func testDoesNotFlagABannedOpenerAwayFromTheClosingParagraph() {
        let body = "In 1954 the ward ran out of the drug and the patient died.\n\n"
            + "Look again at the 1693 tables and the error is obvious.\n\n"
            + filler(words: 460)
            + "\n\nThe machinery outlived the men who wound it, which is the whole story."
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertFalse(findings.contains { finding in
            if case .bannedClosingConstruction = finding { return true }
            return false
        })
    }

    /// The phrase is on the hard list as well, so it fails wherever it appears
    /// — the closing check is about the construction, this is about the words.
    func testNextTimeYouIsHardBannedAnywhereInTheBody() {
        let body = "In 1954 the ward ran out. Next time you weigh flour, the ratio matters.\n\n"
            + filler(words: 500)
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertTrue(findings.contains(.bannedPhrase("next time you")))
    }

    // MARK: - Displayed arithmetic

    func testFlagsASymbolicEquation() {
        let body = "In 1954 someone measured it properly for the first time.\n\n"
            + "\u{03C0} \u{00D7} (15 cm)\u{00B2} \u{00D7} 25 cm\n\n"
            + filler(words: 480)
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertTrue(findings.contains { finding in
            if case .displayedArithmetic = finding { return true }
            return false
        })
    }

    func testFlagsArithmeticWrittenOutInWords() {
        let body = "In 1954 someone measured it properly for the first time.\n\n"
            + "Take 41,250 square degrees, divided by twelve, times 0.7.\n\n"
            + filler(words: 480)
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertTrue(findings.contains { finding in
            if case .displayedArithmetic = finding { return true }
            return false
        })
    }

    /// A multiplier suffix is a fact, not a sum. One symbol is never enough.
    func testAMultiplierIsNotDisplayedArithmetic() {
        XCTAssertFalse(
            LessonQualityCheck.isDisplayedArithmetic(
                "The lamp was 2,400\u{00D7} brighter on the same 1 gallon of oil."
            )
        )
    }

    /// Two arithmetic words and no digits is ordinary prose. The digit
    /// requirement is what stops the word forms firing on it.
    func testTimesAndPlusInProseAreNotArithmetic() {
        XCTAssertFalse(
            LessonQualityCheck.isDisplayedArithmetic(
                "He took it three times a day, plus a fourth dose in winter."
            )
        )
    }

    /// The first false positive this check produced against live prose.
    ///
    /// Markdown puts a whole paragraph on one line, and "*" is its italic
    /// marker — so a 200-word paragraph mentioning Pacioli's *Summa*, with two
    /// ordinary figures somewhere in it, read as two multiplication signs and
    /// two numbers.
    func testItalicsInALongParagraphAreNotAnEquation() {
        let paragraph = "Datini died in 1410 and left roughly 150,000 letters and some 500"
            + " account books, printed in Venice in the *Summa* and read ever since as"
            + " the founding description of the method, though almost none of it is"
            + " arithmetic and the parts that are read as bookkeeping rather than"
            + " calculation, which is the distinction the whole chapter turns on and"
            + " the reason the practice spread the way it did among merchants."
        XCTAssertFalse(LessonQualityCheck.isDisplayedArithmetic(paragraph))
    }

    /// The other half of that fix: word arithmetic still has to be caught when
    /// it is actually displayed, which means on a short line.
    func testWordArithmeticOnAShortLineIsStillCaught() {
        XCTAssertTrue(
            LessonQualityCheck.isDisplayedArithmetic(
                "Take 41,250 square degrees, divided by twelve, times 0.7."
            )
        )
    }

    /// And a symbolic sum is a sum wherever it sits, because neither a chain of
    /// multiplication signs nor an equals sign survives in ordinary prose.
    func testASymbolicSumIsCaughtEvenInsideALongLine() {
        let paragraph = "The derivation runs \u{03C0} \u{00D7} (15 cm)\u{00B2} \u{00D7} 25 cm for"
            + " the cylinder and then again for the cone, which is the point at which"
            + " a reader on a bus stops reading and starts skimming, and the finding"
            + " survives perfectly well stated as prose instead of as a derivation."
        XCTAssertTrue(LessonQualityCheck.isDisplayedArithmetic(paragraph))
    }

    func testACountedFigureIsNotArithmetic() {
        XCTAssertFalse(
            LessonQualityCheck.isDisplayedArithmetic(
                "In 1953, 1,836 people died in a single night."
            )
        )
    }

    // MARK: - Section ceiling

    private func sectioned(_ count: Int, wordsEach: Int) -> String {
        (0..<count)
            .map { "## Section \($0) says something\n\n" + filler(words: wordsEach) }
            .joined(separator: "\n\n")
    }

    func testFlagsMoreSectionsThanTheFormatAllows() {
        let findings = LessonQualityCheck.findings(
            for: lesson(body: sectioned(4, wordsEach: 440)), window: .ten
        )
        XCTAssertTrue(findings.contains(.tooManySections(count: 4, cap: 3, perChapter: false)))
    }

    func testThreeSectionsAtTenMinutesIsTheCeilingNotAViolation() {
        let findings = LessonQualityCheck.findings(
            for: lesson(body: sectioned(3, wordsEach: 590)), window: .ten
        )
        XCTAssertFalse(findings.contains { finding in
            if case .tooManySections = finding { return true }
            return false
        })
    }

    /// The 3-minute format is allowed no headings at all, which is the same
    /// rule expressed as a ceiling of zero.
    func testAnySectionAtThreeMinutesIsOverTheCeiling() {
        let findings = LessonQualityCheck.findings(
            for: lesson(body: sectioned(1, wordsEach: 520)), window: .three
        )
        XCTAssertTrue(findings.contains(.tooManySections(count: 1, cap: 0, perChapter: false)))
    }

    private func course(chapters: Int, sectionsEach: Int) -> String {
        (1...chapters)
            .map { number in
                LessonFormat.chapterHeading(number: number, text: "What it establishes")
                    + "\n\n" + sectioned(sectionsEach, wordsEach: 400)
            }
            .joined(separator: "\n\n")
    }

    /// A course's chapter headings are its structure, not its sections —
    /// counting them against the same ceiling would flag every course.
    func testChapterHeadingsDoNotCountTowardsACoursesSectionCeiling() {
        let findings = LessonQualityCheck.findings(
            for: lesson(body: course(chapters: 4, sectionsEach: 3)), window: .thirty
        )
        XCTAssertFalse(findings.contains { finding in
            if case .tooManySections = finding { return true }
            return false
        })
    }

    func testFlagsAChapterThatCarriesTooManySections() {
        let body = course(chapters: 3, sectionsEach: 2)
            + "\n\n" + LessonFormat.chapterHeading(number: 4, text: "The last one")
            + "\n\n" + sectioned(5, wordsEach: 300)
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .thirty)
        XCTAssertTrue(findings.contains(.tooManySections(count: 5, cap: 3, perChapter: true)))
    }

    // MARK: - Subtitle

    /// Compared on stems, because the giveaway is a restatement rather than a
    /// quotation: "they failed at geometry" and "the failure was geometric"
    /// share no whole word at all.
    func testFlagsASubtitleThatRestatesTheClaimInOtherWords() {
        XCTAssertTrue(
            LessonQualityCheck.subtitleGivesAwayClaim(
                subtitle: "Gothic builders never came close to crushing their stone. They failed at geometry instead",
                claim: "Their failure was geometric, never material: the stone was never near crushing"
            )
        )
    }

    func testASubtitleThatOnlyTeasesTheClaimSurvives() {
        XCTAssertFalse(
            LessonQualityCheck.subtitleGivesAwayClaim(
                subtitle: "A jar of flour and water that has outlived several countries",
                claim: "What a starter inherits is the arrangement of roles, not the organisms filling them"
            )
        )
    }

    /// Every fixture subtitle is a window label ("A 10-minute explainer"), too
    /// short to compare against anything. Guarding the floor explicitly so a
    /// future short subtitle cannot start failing on two coincidental stems.
    func testAShortSubtitleIsNeverJudged() {
        XCTAssertFalse(
            LessonQualityCheck.subtitleGivesAwayClaim(
                subtitle: "A 10-minute explainer", claim: "The correction is the cause"
            )
        )
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

    /// The advisory words (unlock, harness, leverage, landscape, realm) are
    /// ordinary nouns and verbs a genuine topic can need — a lesson on
    /// carriages needs "harness," one on Constable needs "landscape." They
    /// must never fail a lesson mechanically, in any form. That judgment is
    /// left entirely to the revision pass's prompt.
    func testAdvisoryWordsAreNeverMechanicallyFlagged() {
        let body = "In 1974 the harness maker fitted a leather landscape strap to unlock"
            + " the fund's leverage across every realm of the estate. " + filler(words: 520)
        let findings = LessonQualityCheck.findings(for: lesson(body: body), window: .three)
        XCTAssertFalse(findings.contains { finding in
            if case .bannedPhrase(let phrase) = finding {
                return Prompts.advisoryBannedPhrases.contains(phrase)
            }
            return false
        })
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
