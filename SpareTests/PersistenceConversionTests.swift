import XCTest
import SwiftData
import SpareCore
@testable import Spare

/// The iOS-side contract: every SwiftData model converts losslessly to and from
/// the SpareCore value types. Core logic is tested in the SpareCore package.
final class PersistenceConversionTests: XCTestCase {

    private func inMemoryContext() -> ModelContext {
        ModelContext(PersistenceStack.makeContainer(inMemory: true))
    }

    // MARK: - Profile

    func testProfileRoundTrip() {
        let snapshot = ProfileSnapshot(
            interests: ["economic history", "materials"],
            work: "physiotherapist",
            curiosityGaps: ["how interest rates work"],
            complexity: .dense
        )
        XCTAssertEqual(StoredProfile(snapshot: snapshot).snapshot, snapshot)
    }

    func testProfileApplyOverwritesEveryField() {
        let stored = StoredProfile(snapshot: .empty)
        let updated = ProfileSnapshot(interests: ["a"], work: "b", curiosityGaps: ["c"], complexity: .plain)
        stored.apply(updated)
        XCTAssertEqual(stored.snapshot, updated)
    }

    func testUnknownComplexityFallsBackToStandard() {
        let stored = StoredProfile(snapshot: .empty)
        stored.complexityRaw = "nonsense-from-a-future-version"
        XCTAssertEqual(stored.complexity, .standard)
    }

    // MARK: - Lesson

    func testLessonRoundTrip() {
        let lesson = MockProvider.fixtureLesson(
            topic: MockProvider.fixtureSuggestions(for: .ten)[0],
            window: .ten
        )
        let stored = StoredLesson(lesson: lesson, window: .ten)
        XCTAssertEqual(stored.lesson, lesson)
        XCTAssertEqual(stored.window, .ten)
        XCTAssertEqual(stored.angles.count, 3)
    }

    func testUnknownWindowFallsBackToShortest() {
        let stored = StoredLesson(
            title: "t", subtitle: "s", topicTag: "d", window: .ten,
            bodyMarkdown: "body", surprisingClaim: "c", deeperAngles: []
        )
        stored.windowRaw = "ninety"
        XCTAssertEqual(stored.window, .three)
    }

    func testApplyRevisedReplacesTheCanonicalBody() {
        let stored = StoredLesson(
            title: "draft title", subtitle: "s", topicTag: "d", window: .three,
            bodyMarkdown: "draft body", surprisingClaim: "", deeperAngles: []
        )
        let revised = Lesson(
            title: "revised title", subtitle: "revised subtitle", domainTag: "Engineering",
            bodyMarkdown: "revised body", surprisingClaim: "claim",
            deeperAngles: ["a", "b", "c"]
        )
        stored.applyRevised(revised)
        XCTAssertEqual(stored.lesson, revised)
    }

    func testDigestCarriesCompletionState() {
        let stored = StoredLesson(
            title: "Why bridges hum", subtitle: "s", topicTag: "Engineering",
            window: .three, bodyMarkdown: "b"
        )
        XCTAssertNil(stored.digest.completedAt)
        let now = Date()
        stored.completedAt = now
        XCTAssertEqual(stored.digest, LessonDigest(title: "Why bridges hum", topicTag: "Engineering", completedAt: now))
    }

    func testMinutesRemainingUsesCoreReadingTimeMath() {
        let body = Array(repeating: "word", count: 1_800).joined(separator: " ")
        let stored = StoredLesson(title: "t", subtitle: "s", topicTag: "d", window: .ten, bodyMarkdown: body)
        XCTAssertEqual(stored.wordCount, 1_800)
        XCTAssertEqual(stored.minutesRemaining, ReadingTime.minutesRemaining(totalWordCount: 1_800, progress: 0))
        stored.scrollProgress = 1
        XCTAssertEqual(stored.minutesRemaining, 0)
    }

    // MARK: - Recall

    func testRecallItemRoundTripAndFirstDueDate() {
        let question = RecallQuestion(
            question: "q", answer: "a",
            distractors: ["b", "c", "d"], explanation: "because"
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let stored = StoredRecallItem(question: question, lessonID: UUID(), now: now, calendar: calendar)

        XCTAssertEqual(stored.recallQuestion, question)
        XCTAssertEqual(stored.intervalStage, 0)
        XCTAssertEqual(stored.lastResult, .unseen)
        XCTAssertEqual(stored.dueAt, calendar.date(byAdding: .day, value: 1, to: now))
        XCTAssertFalse(stored.isDue(at: now))
        XCTAssertTrue(stored.isDue(at: now.addingTimeInterval(86_401)))
    }

    func testRecallOptionsAreStableAndContainTheAnswer() {
        let question = RecallQuestion(
            question: "q", answer: "correct",
            distractors: ["w1", "w2", "w3"], explanation: "e"
        )
        let stored = StoredRecallItem(question: question, lessonID: UUID())
        XCTAssertEqual(stored.options.count, 4)
        XCTAssertTrue(stored.options.contains("correct"))
        XCTAssertEqual(stored.options, stored.options, "order must not change between reads")
    }

    func testRecordingCorrectAdvancesTheSchedule() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let stored = StoredRecallItem(
            question: RecallQuestion(question: "q", answer: "a", distractors: ["b", "c", "d"], explanation: "e"),
            lessonID: UUID(), now: now, calendar: calendar
        )
        stored.record(correct: true, now: now, calendar: calendar)
        XCTAssertEqual(stored.intervalStage, 1)
        XCTAssertEqual(stored.lastResult, .correct)
        XCTAssertEqual(stored.dueAt, calendar.date(byAdding: .day, value: 3, to: now))
    }

    func testRecordingIncorrectGoesBackAStage() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let stored = StoredRecallItem(
            question: RecallQuestion(question: "q", answer: "a", distractors: ["b", "c", "d"], explanation: "e"),
            lessonID: UUID(), now: now, calendar: calendar
        )
        stored.intervalStage = 3
        stored.record(correct: false, now: now, calendar: calendar)
        XCTAssertEqual(stored.intervalStage, 2)
        XCTAssertEqual(stored.lastResult, .incorrect)
        XCTAssertEqual(stored.dueAt, calendar.date(byAdding: .day, value: 7, to: now))
    }

    // MARK: - Suggestion cache

    func testSuggestionCacheRoundTrip() {
        let suggestions = MockProvider.fixtureSuggestions(for: .fifteen)
        let cache = StoredSuggestionCache(window: .fifteen, suggestions: suggestions)
        XCTAssertEqual(cache.suggestions, suggestions)
        XCTAssertEqual(cache.window, .fifteen)
    }

    func testSuggestionCacheSetterReplacesContents() {
        let cache = StoredSuggestionCache(window: .three, suggestions: [])
        XCTAssertTrue(cache.suggestions.isEmpty)
        cache.suggestions = MockProvider.fixtureSuggestions(for: .three)
        XCTAssertEqual(cache.suggestions.count, 5)
    }

    func testCorruptSuggestionDataDecodesToEmptyRatherThanCrashing() {
        let cache = StoredSuggestionCache(window: .three, suggestions: [])
        cache.suggestionsData = Data("not json".utf8)
        XCTAssertTrue(cache.suggestions.isEmpty)
    }

    func testStalenessIsAboutRefreshNotDisplay() {
        let cache = StoredSuggestionCache(
            window: .three, suggestions: [], generatedAt: Date().addingTimeInterval(-7 * 3_600)
        )
        XCTAssertTrue(cache.isStale())
        XCTAssertFalse(cache.isStale(maxAge: 24 * 3_600))
    }

    // MARK: - Entitlement

    func testEntitlementRoundTrip() {
        let snapshot = EntitlementSnapshot(
            tier: .yearly, freeLessonsUsedToday: 2, lastFreeLessonDate: Date()
        )
        let stored = StoredEntitlement()
        stored.apply(snapshot)
        XCTAssertEqual(stored.snapshot, snapshot)
    }

    func testUnknownTierFallsBackToFree() {
        let stored = StoredEntitlement(tier: .lifetime)
        stored.tierRaw = "platinum"
        XCTAssertEqual(stored.tier, .free)
    }

    func testGatingDecisionsComeFromCoreRules() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let stored = StoredEntitlement()
        XCTAssertEqual(
            EntitlementRules.canStartLesson(stored.snapshot, window: .three, now: now, calendar: calendar),
            .allowed
        )
        XCTAssertEqual(
            EntitlementRules.canStartLesson(stored.snapshot, window: .thirty, now: now, calendar: calendar),
            .denied(.lockedWindow(.thirty))
        )
    }

    // MARK: - Container

    /// The store path must sit under a directory that exists. `Application
    /// Support` is absent in a fresh app container, which is what broke store
    /// creation at launch.
    func testStoreURLParentDirectoryExists() {
        let url = PersistenceStack.storeURL()
        XCTAssertEqual(url.lastPathComponent, "Spare.store")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
            "store directory was not created: \(url.deletingLastPathComponent().path)"
        )
    }

    func testSchemaCoversEveryPersistedModel() {
        let names = Set(PersistenceStack.makeSchema().entities.map(\.name))
        for expected in [
            "StoredProfile", "StoredLesson", "StoredRecallItem",
            "StoredSuggestionCache", "StoredEntitlement",
        ] {
            XCTAssertTrue(names.contains(expected), "schema is missing \(expected)")
        }
    }

    func testModelsInsertAndFetchFromAnInMemoryContainer() throws {
        let context = inMemoryContext()
        let lesson = MockProvider.fixtureLesson(
            topic: MockProvider.fixtureSuggestions(for: .three)[0], window: .three
        )
        context.insert(StoredLesson(lesson: lesson, window: .three))
        context.insert(StoredProfile(snapshot: .empty))
        context.insert(StoredEntitlement())
        try context.save()

        let stored = try context.fetch(FetchDescriptor<StoredLesson>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.lesson, lesson)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredProfile>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredEntitlement>()).count, 1)
    }
}
