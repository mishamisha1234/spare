import XCTest
@testable import SpareCore

/// The negated-scope pivot, measured against every lesson that produced one.
///
/// These are not invented examples. They are every appearance the construction
/// actually made across the 39 generated lessons of probe rounds 2-8 — the
/// corpus the detector was designed against — quoted verbatim. A detector tuned
/// on examples someone imagined would be tuned on the wrong distribution.
///
/// What this corpus proves and does not prove is worth being clear about. It
/// proves the check fires on what the model actually writes and stays silent on
/// the one near-miss those lessons produced. It proves nothing about how often
/// the construction appears: that rate is ~46% pooled and no single probe round
/// was distinguishable from it. See README, "What the probe rounds did and did
/// not show".
final class NegatedScopePivotTests: XCTestCase {

    /// Every real appearance. All of them must fire.
    static let corpus: [(round: String, lesson: String, text: String)] = [
        (round: "round2", lesson: "01", text: "None of this happens in a single pass."),
        (round: "round2", lesson: "03", text: "None of this happens at a fixed speed, which is the detail that trips up most people who move from commercial yeast to a starter for the first time."),
        (round: "round2", lesson: "04", text: "None of this worked without maintenance, and that is where the elegance of the design met the grind of empire."),
        (round: "round2", lesson: "06", text: "None of this happened quickly."),
        (round: "round3", lesson: "01", text: "None of this happens in a single pass."),
        (round: "round3", lesson: "02", text: "None of this, on its own, produces a regular beat."),
        (round: "round3", lesson: "03", text: "None of this is exotic."),
        (round: "round3", lesson: "05", text: "None of this machinery exists purely for hiding."),
        (round: "round3", lesson: "06", text: "None of this was imposed by any authority."),
        (round: "round4", lesson: "03", text: "None of this shows up on day one."),
        (round: "round5", lesson: "03", text: "None of this is exotic."),
        (round: "round5", lesson: "04", text: "None of this was accidental improvisation solved fresh at every site."),
        (round: "round6", lesson: "03", text: "None of this requires any added commercial yeast because the wild yeast and bacteria that make it work were never absent from flour in the first place; a starter simply gives them water, warmth, and repeated feeding, and lets the population that flour already carries grow large enough to leaven bread on its own."),
        (round: "round6", lesson: "05", text: "None of that is possible on a hormonal timetable measured in minutes."),
        (round: "round7", lesson: "03", text: "None of this is visible and none of it is added on purpose."),
        (round: "round7", lesson: "05", text: "None of this resolves the puzzle from the opening claim so much as sharpen it: an animal that can't perceive color is nonetheless generating a color display precise enough to fool predators that can."),
        (round: "round7", lesson: "06", text: "None of this has anything to do with pronunciation or meaning."),
        (round: "round8", lesson: "01", text: "None of this required any single dramatic event."),
        (round: "round8", lesson: "03", text: "None of this required the kind of domestication that produced commercial yeast."),
        (round: "round8", lesson: "04", text: "None of that layering would have mattered without the shape of the surface, and this is where the engineering becomes almost simple in retrospect."),
        (round: "round8", lesson: "05", text: "None of that explains how an animal with no color vision manages to match colors it cannot see."),
        (round: "round8", lesson: "06", text: "None of this touches meaning."),
        (round: "round8", lesson: "06", text: "None of this happened quickly, and it is worth being precise about how slow it actually was."),
    ]

    /// Contains the words, is not the construction: an ordinary mid-sentence
    /// comparative. Must never fire. This is the reason the check is a
    /// sentence-prefix test and not a substring search.
    static let nearMisses: [(round: String, lesson: String, text: String)] = [
        (round: "round3", lesson: "03", text: "Commercial yeast bread has none of this complexity, because it has no bacteria in it at all — just one organism, doing one job, as fast as possible."),
    ]

    func testEveryRealInstanceIsCaught() {
        for entry in Self.corpus {
            XCTAssertEqual(
                LessonQualityCheck.negatedScopePivot(in: entry.text),
                entry.text,
                "missed \(entry.round)/\(entry.lesson): \(entry.text)"
            )
        }
        XCTAssertEqual(Self.corpus.count, 23, "corpus changed; re-check the detector")
    }

    func testNearMissesNeverFire() {
        for entry in Self.nearMisses {
            XCTAssertNil(
                LessonQualityCheck.negatedScopePivot(in: entry.text),
                "false positive on \(entry.round)/\(entry.lesson): \(entry.text)"
            )
        }
        XCTAssertFalse(Self.nearMisses.isEmpty, "the near-miss corpus must not be empty")
    }

    /// Prose that shares vocabulary with the construction without being it.
    func testOrdinaryProseDoesNotFire() {
        let clean = [
            "Commercial yeast bread has none of this complexity.",
            "The balance between two competing bacterial byproducts is what bakers taste.",
            "There is none left by morning.",
            "He kept none of that correspondence.",
            "Nothing about this was accidental.",
        ]
        for sentence in clean {
            XCTAssertNil(LessonQualityCheck.negatedScopePivot(in: sentence), sentence)
        }
    }

    /// Headings are not prose, and every other check in this file skips them.
    func testHeadingsAreIgnored() {
        XCTAssertNil(LessonQualityCheck.negatedScopePivot(in: "## None of this matters"))
    }

    /// Mid-paragraph, after other sentences: the common shape in the corpus.
    func testFiresMidParagraphNotOnlyAtTheStart() {
        let body = "A paragraph of setup runs first. None of this happens in a single pass. Then more."
        XCTAssertEqual(
            LessonQualityCheck.negatedScopePivot(in: body),
            "None of this happens in a single pass."
        )
    }

    /// The finding must carry the sentence — that is the whole reason the retry
    /// is worth more than a bare re-run. See `Prompts.revisionPivotTemplate`.
    func testFindingCarriesTheSentenceAndWarrantsRetry() {
        let body = "Setup here. None of this happens in a single pass. Then more."
        let findings = LessonQualityCheck.retryTriggeringFindings(inBody: body)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.offendingSentence, "None of this happens in a single pass.")
        XCTAssertEqual(findings.first?.warrantsRetry, true)
    }

    func testCleanBodyProducesNoRetryTriggeringFindings() {
        XCTAssertTrue(
            LessonQualityCheck.retryTriggeringFindings(inBody: "Perfectly ordinary prose.").isEmpty
        )
    }

    /// The twelve pre-existing findings stay advisory. If this fails, something
    /// has made an ordinary style note start costing a whole extra pass — which
    /// on `wellUnderBudget` alone would retry most lessons that miss the floor.
    func testOnlyThePivotWarrantsRetry() {
        let others: [LessonQualityCheck.Finding] = [
            .bannedPhrase("delve"),
            .overBudget(words: 9, limit: 8),
            .wellUnderBudget(words: 1, floor: 9),
            .opensWithDefinition("X is a Y"),
            .containsEmoji,
            .closingRestatesOpening,
            .wrongDeeperAngleCount(2),
            .uniformSentenceLength(mean: 18),
            .bannedClosingConstruction("look again at"),
            .displayedArithmetic("2 = 2"),
            .tooManySections(count: 9, cap: 3, perChapter: false),
            .subtitleGivesAwayClaim,
        ]
        for finding in others {
            XCTAssertFalse(finding.warrantsRetry, "\(finding) must stay advisory")
            XCTAssertNil(finding.offendingSentence, "\(finding)")
        }
    }

    /// The retry prompt names the sentence rather than describing the shape.
    /// Describing the shape is what the editorial prompt already does, in three
    /// formulations, none of which moved the rate.
    func testRevisionPromptQuotesTheOffendingSentence() {
        let sentence = "None of this happens in a single pass."
        let prompt = Prompts.revisionTaskPrompt(
            wordBudget: 1100...1400,
            draftJSON: "{}",
            retry: .bannedConstruction(sentence: sentence)
        )
        XCTAssertTrue(prompt.contains(sentence), prompt)
        XCTAssertTrue(prompt.contains("banned construction"), prompt)
        XCTAssertTrue(PromptTemplate.unresolvedPlaceholders(in: prompt).isEmpty, prompt)
        // The two reasons must not bleed into each other.
        XCTAssertFalse(prompt.contains("below the"), prompt)
    }
}
