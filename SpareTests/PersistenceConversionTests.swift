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
            topic: MockProvider.fixtureSuggestions(for: .seven)[0],
            window: .seven
        )
        let stored = StoredLesson(lesson: lesson, window: .seven)
        XCTAssertEqual(stored.lesson, lesson)
        XCTAssertEqual(stored.window, .seven)
        XCTAssertEqual(stored.angles.count, 3)
    }

    func testUnknownWindowFallsBackToShortest() {
        let stored = StoredLesson(
            title: "t", subtitle: "s", topicTag: "d", window: .seven,
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
        let stored = StoredLesson(title: "t", subtitle: "s", topicTag: "d", window: .seven, bodyMarkdown: body)
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
    // MARK: - Legacy window migration

    /// The reader's library survives a length being renamed.
    ///
    /// The spec asked for this by name, and the reason is that the failure is
    /// silent. A row written as `"ten"` decodes to nil through the plain
    /// initialiser, the call site's `?? .three` turns it into a 3-minute One
    /// Thing, and a 1,300-word explainer sits in the library labelled as
    /// something it is not. Nothing crashes, nothing logs, and nobody reports
    /// it because the lesson is still readable.
    func testTenMinuteLessonsMigrateToSeven() throws {
        let context = inMemoryContext()
        let lesson = StoredLesson(
            title: "How standard time was imposed", subtitle: "s", topicTag: "History",
            window: .seven, bodyMarkdown: "Body."
        )
        // Written the way a build from before the rename would have written it.
        lesson.windowRaw = "ten"
        context.insert(lesson)
        try context.save()

        let moved = PersistenceStack.normalizeLegacyWindows(in: context)

        XCTAssertEqual(moved.lessons, 1)
        XCTAssertEqual(lesson.windowRaw, "seven", "the stored value still says ten")
        XCTAssertEqual(lesson.window, .seven)
        XCTAssertEqual(lesson.window.format, .explainer, "an explainer must stay an explainer")
    }

    /// And the 45-minute course, which is the same rule and was already relied on.
    func testFortyFiveMinuteCoursesMigrateToThirty() throws {
        let context = inMemoryContext()
        let course = StoredLesson(
            title: "How planes got safe", subtitle: "s", topicTag: "Engineering",
            window: .thirty, bodyMarkdown: "Body."
        )
        course.windowRaw = "fortyFive"
        context.insert(course)
        try context.save()

        PersistenceStack.normalizeLegacyWindows(in: context)

        XCTAssertEqual(course.windowRaw, "thirty")
        XCTAssertEqual(course.window.format, .miniCourse)
    }

    /// A suggestion cache row is deleted rather than renamed, and this is the
    /// reason: `windowRaw` is unique, so renaming `"ten"` to `"seven"` beside an
    /// existing `"seven"` row is a constraint violation that fails the whole
    /// save — taking the lesson rewrites down with it.
    func testLegacySuggestionCachesAreDroppedRatherThanCollidingOnTheUniqueKey() throws {
        let context = inMemoryContext()
        let current = StoredSuggestionCache(window: .seven, suggestions: [])
        context.insert(current)
        let stale = StoredSuggestionCache(window: .three, suggestions: [])
        stale.windowRaw = "ten"
        context.insert(stale)
        try context.save()

        let moved = PersistenceStack.normalizeLegacyWindows(in: context)

        XCTAssertEqual(moved.caches, 1)
        let remaining = try context.fetch(FetchDescriptor<StoredSuggestionCache>())
        XCTAssertEqual(remaining.map(\.windowRaw), ["seven"], "the stale row survived, or the live one did not")
    }

    /// The migration must be safe to run on every launch, which is when it runs.
    func testMigrationIsIdempotentAndLeavesCurrentRowsAlone() throws {
        let context = inMemoryContext()
        let current = StoredLesson(
            title: "t", subtitle: "s", topicTag: "d", window: .seven, bodyMarkdown: "Body."
        )
        context.insert(current)
        let stale = StoredLesson(
            title: "t", subtitle: "s", topicTag: "d", window: .seven, bodyMarkdown: "Body."
        )
        stale.windowRaw = "ten"
        context.insert(stale)
        try context.save()

        XCTAssertEqual(PersistenceStack.normalizeLegacyWindows(in: context).lessons, 1)
        XCTAssertEqual(
            PersistenceStack.normalizeLegacyWindows(in: context).lessons, 0,
            "a second run must find nothing left to do"
        )
        XCTAssertEqual(current.windowRaw, "seven")
    }

    /// The decoder and the migration read the same table. If they ever
    /// disagreed, the library would show one window and the stored row would
    /// say another, and only one of them would survive the next write.
    func testEveryLegacyRawValueDecodesToTheWindowTheMigrationWritesIt() {
        XCTAssertFalse(TimeWindow.legacyRawValues.isEmpty)
        for (raw, expected) in TimeWindow.legacyRawValues {
            XCTAssertEqual(TimeWindow.stored(rawValue: raw), expected, raw)
            XCTAssertNil(TimeWindow(rawValue: raw), "\(raw) is still a live case, not a legacy one")
        }
    }

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
