import XCTest
@testable import SpareCore

final class SuggestionValidatorTests: XCTestCase {

    private func validSet() -> [TopicSuggestion] {
        [
            TopicSuggestion(title: "Why bridges hum", hook: "Wind makes steel sing on purpose.", domainTag: "Engineering"),
            TopicSuggestion(title: "The florin that priced Europe", hook: "One coin set rates for centuries.", domainTag: "History"),
            TopicSuggestion(title: "Why knees predict rain", hook: "Pressure moves joint fluid enough to feel.", domainTag: "Biology"),
            TopicSuggestion(title: "Surge pricing before computers", hook: "Fish markets got there first.", domainTag: "Economics"),
            TopicSuggestion(title: "Why choirs drift sharp", hook: "Group pitch rises, and physics insists.", domainTag: "Music", isWildcard: true),
        ]
    }

    func testAValidSetPassesCleanly() {
        XCTAssertEqual(SuggestionValidator.validate(validSet()), [])
        XCTAssertTrue(SuggestionValidator.isAcceptable(validSet()))
    }

    func testWrongCountIsBlocking() {
        let issues = SuggestionValidator.validate(Array(validSet().prefix(4)))
        XCTAssertTrue(issues.contains(.wrongCount(4)))
        XCTAssertFalse(SuggestionValidator.isAcceptable(Array(validSet().prefix(4))))
    }

    func testTooFewDomainsIsBlocking() {
        var set = validSet()
        for index in set.indices {
            set[index].domainTag = "History"
        }
        let issues = SuggestionValidator.validate(set)
        XCTAssertTrue(issues.contains(.tooFewDomains(1)))
        XCTAssertFalse(SuggestionValidator.isAcceptable(set))
    }

    func testExactlyThreeDomainsIsEnough() {
        var set = validSet()
        set[0].domainTag = "History"
        set[1].domainTag = "History"
        set[2].domainTag = "Biology"
        set[3].domainTag = "Biology"
        set[4].domainTag = "Music"
        XCTAssertTrue(SuggestionValidator.isAcceptable(set))
    }

    func testDomainComparisonIgnoresCaseAndPunctuation() {
        var set = validSet()
        set[0].domainTag = "Economic history"
        set[1].domainTag = "economic history"
        let issues = SuggestionValidator.validate(set)
        XCTAssertTrue(issues.contains(.tooFewDomains(4)))
    }

    func testMissingWildcardIsBlocking() {
        var set = validSet()
        set[4].isWildcard = false
        XCTAssertTrue(SuggestionValidator.validate(set).contains(.wildcardCount(0)))
        XCTAssertFalse(SuggestionValidator.isAcceptable(set))
    }

    func testTwoWildcardsIsBlocking() {
        var set = validSet()
        set[0].isWildcard = true
        XCTAssertTrue(SuggestionValidator.validate(set).contains(.wildcardCount(2)))
    }

    func testOverLongTitleIsFlaggedButNotBlocking() {
        var set = validSet()
        set[0].title = "One two three four five six seven eight"
        let issues = SuggestionValidator.validate(set)
        XCTAssertTrue(issues.contains(.titleTooLong(title: set[0].title, words: 8)))
        XCTAssertTrue(SuggestionValidator.isAcceptable(set), "length slips are repaired, not blocking")
    }

    func testSevenWordTitleIsAllowed() {
        var set = validSet()
        set[0].title = "One two three four five six seven"
        XCTAssertFalse(SuggestionValidator.validate(set).contains { issue in
            if case .titleTooLong = issue { return true }
            return false
        })
    }

    func testOverLongHookIsFlagged() {
        var set = validSet()
        set[1].hook = Array(repeating: "word", count: 15).joined(separator: " ")
        XCTAssertTrue(SuggestionValidator.validate(set).contains(.hookTooLong(title: set[1].title, words: 15)))
    }

    func testClickbaitIsFlagged() {
        var set = validSet()
        set[2].title = "You won't believe this bridge"
        let issues = SuggestionValidator.validate(set)
        XCTAssertTrue(issues.contains(.clickbait(title: set[2].title, phrase: "you won't believe")))
    }

    func testEmptyFieldIsBlocking() {
        var set = validSet()
        set[3].hook = "   "
        XCTAssertTrue(SuggestionValidator.validate(set).contains(.emptyField(title: set[3].title, field: "hook")))
        XCTAssertFalse(SuggestionValidator.isAcceptable(set))
    }

    // MARK: - History dedup

    func testRepeatOfRecentLessonIsBlocking() {
        let history = [LessonDigest(title: "Why bridges hum", topicTag: "Engineering", completedAt: Date())]
        let issues = SuggestionValidator.validate(validSet(), history: history)
        XCTAssertTrue(issues.contains(.duplicateOfHistory(title: "Why bridges hum")))
        XCTAssertFalse(SuggestionValidator.isAcceptable(validSet(), history: history))
    }

    func testHistoryMatchIgnoresCaseAndPunctuation() {
        let history = [LessonDigest(title: "WHY BRIDGES HUM!", topicTag: "Engineering", completedAt: Date())]
        XCTAssertFalse(SuggestionValidator.isAcceptable(validSet(), history: history))
    }

    func testOnlyTheMostRecentThirtyLessonsAreExcluded() {
        let now = Date()
        // 30 recent unrelated lessons, plus an older lesson matching a suggestion.
        var history = (0..<30).map { index in
            LessonDigest(
                title: "Unrelated \(index)",
                topicTag: "Misc",
                completedAt: now.addingTimeInterval(TimeInterval(-index * 60))
            )
        }
        history.append(LessonDigest(
            title: "Why bridges hum",
            topicTag: "Engineering",
            completedAt: now.addingTimeInterval(-999_999)
        ))
        XCTAssertTrue(
            SuggestionValidator.isAcceptable(validSet(), history: history),
            "a lesson outside the 30-lesson window may be suggested again"
        )
    }

    func testDuplicateWithinTheSameSetIsBlocking() {
        var set = validSet()
        set[1].title = set[0].title
        XCTAssertTrue(SuggestionValidator.validate(set).contains(.duplicateWithinSet(title: set[0].title)))
        XCTAssertFalse(SuggestionValidator.isAcceptable(set))
    }

    // MARK: - Curiosity gaps

    func testCuriosityGapConnectionIsCheckedWhenGapsExist() {
        let profile = ProfileSnapshot(curiosityGaps: ["monetary policy"])
        XCTAssertTrue(SuggestionValidator.validate(validSet(), profile: profile).contains(.noCuriosityGapConnection))
    }

    func testConnectionIsSatisfiedByLexicalOverlap() {
        let profile = ProfileSnapshot(curiosityGaps: ["how bridges stay up"])
        XCTAssertFalse(
            SuggestionValidator.validate(validSet(), profile: profile).contains(.noCuriosityGapConnection)
        )
    }

    func testNoGapsMeansNoConnectionRequirement() {
        XCTAssertFalse(
            SuggestionValidator.validate(validSet(), profile: .empty).contains(.noCuriosityGapConnection)
        )
    }

    func testGapConnectionIsNeverBlocking() {
        let profile = ProfileSnapshot(curiosityGaps: ["quantum chromodynamics"])
        XCTAssertTrue(SuggestionValidator.isAcceptable(validSet(), profile: profile))
    }

    // MARK: - Repair

    func testRepairTrimsOverLongTitlesAndHooks() {
        var set = validSet()
        set[0].title = "One two three four five six seven eight nine"
        set[0].hook = Array(repeating: "w", count: 20).joined(separator: " ")
        let repaired = SuggestionValidator.repairing(set)
        XCTAssertEqual(repaired[0].title.lessonWordCount, 7)
        XCTAssertEqual(repaired[0].hook.lessonWordCount, 14)
    }

    func testRepairLeavesCompliantTextAlone() {
        let repaired = SuggestionValidator.repairing(validSet())
        XCTAssertEqual(repaired.map(\.title), validSet().map(\.title))
        XCTAssertEqual(repaired.map(\.hook), validSet().map(\.hook))
    }

    func testRepairPreservesIdentityAndWildcardFlag() {
        let original = validSet()
        let repaired = SuggestionValidator.repairing(original)
        XCTAssertEqual(repaired.map(\.id), original.map(\.id))
        XCTAssertEqual(repaired.map(\.isWildcard), original.map(\.isWildcard))
    }

    // MARK: - Every mock fixture must pass its own validator

    func testMockFixturesAreValidForEveryWindow() {
        for window in TimeWindow.allCases {
            let issues = SuggestionValidator.validate(MockProvider.fixtureSuggestions(for: window))
            XCTAssertEqual(issues, [], "\(window) fixtures: \(issues.map(\.description))")
        }
    }
}
