import XCTest
@testable import SpareCore

/// The client half of the reverse trial.
///
/// Everything here is about what the app *draws*. The server decides what it
/// serves, and re-checks the same limits atomically before generating — so a
/// disagreement between these two costs a misdrawn circle, not a lesson.
final class TrialRulesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func active(lessons: Int = 10, courses: Int = 2, daysLeft: Double = 7) -> EntitlementSnapshot {
        EntitlementSnapshot(
            tier: .trialing,
            trial: TrialMirror(
                status: .active,
                remainingLessons: lessons,
                remainingCourses: courses,
                startedAt: now.addingTimeInterval(-(7 - daysLeft) * 86_400),
                expiresAt: now.addingTimeInterval(daysLeft * 86_400)
            )
        )
    }

    // MARK: - Decoding what the server sends

    func testDecodesTheServersShape() throws {
        let json = """
        {"status":"active","remainingLessons":6,"remainingCourses":1,
         "startedAt":1800000000000,"expiresAt":1800604800000}
        """
        let mirror = try JSONDecoder().decode(TrialMirror.self, from: Data(json.utf8))

        XCTAssertEqual(mirror.status, .active)
        XCTAssertEqual(mirror.remainingLessons, 6)
        XCTAssertEqual(mirror.remainingCourses, 1)
        // Milliseconds on the wire, `Date` everywhere in Swift.
        XCTAssertEqual(mirror.startedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(mirror.expiresAt, Date(timeIntervalSince1970: 1_800_604_800))
    }

    func testRoundTripsThroughItsOwnEncoding() throws {
        let original = active(lessons: 3, courses: 0, daysLeft: 2).trial
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(TrialMirror.self, from: data), original)
    }

    /// An unrecognised status fails to decode rather than falling back.
    ///
    /// It used to fall back to `ended`, on the reasoning that a server growing
    /// a fourth state must not brick an older client. That was backwards:
    /// `ended` is the status that fires the day-7 summary, so the "safe"
    /// default was the one that invents a finished week. Throwing gives the
    /// caller nil, and nil means the app keeps what it had.
    func testAnUnknownStatusFailsToDecodeRatherThanGuessing() {
        let json = #"{"status":"paused","remainingLessons":4}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TrialMirror.self, from: Data(json.utf8)))
    }

    // MARK: - A failed read is not an answer

    /// The bug this whole guard exists for.
    ///
    /// A mirror claiming `ended` with no recorded start is not a finished
    /// week; it is noise that reached the property. Before `hasEnded` required
    /// a start, that noise fired the day-7 summary at readers who had never
    /// had a trial -- and with no `startedAt` to count from, the summary
    /// totalled their entire library and presented it as their week.
    func testEndedWithoutAStartIsNotAFinishedWeek() {
        let noise = TrialMirror(status: .ended)
        XCTAssertFalse(noise.hasEnded)

        let real = TrialMirror(
            status: .ended,
            startedAt: now.addingTimeInterval(-8 * 86_400),
            expiresAt: now.addingTimeInterval(-86_400)
        )
        XCTAssertTrue(real.hasEnded)
    }

    func testAnUnreachableStoreAnswersNothingAtAll() async {
        let store = UnreachableTrialStore()
        let status = await store.status()
        let started = await store.start()
        XCTAssertNil(status, "a failed read must not resolve to a state")
        XCTAssertNil(started, "a failed claim must not resolve to a refusal")
    }

    // MARK: - Counting down

    /// Rounded up, so the last part-day reads as "1 day left" rather than
    /// "0 days left" on the morning somebody still has hours.
    func testDaysRemainingRoundsUp() {
        XCTAssertEqual(active(daysLeft: 3).trial.daysRemaining(now: now), 3)
        XCTAssertEqual(active(daysLeft: 2.4).trial.daysRemaining(now: now), 3)
        XCTAssertEqual(active(daysLeft: 0.1).trial.daysRemaining(now: now), 1)
    }

    func testAnEndedTrialHasNoDaysLeft() {
        let ended = TrialMirror(status: .ended, expiresAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(ended.daysRemaining(now: now), 0)
    }

    /// The day-4 nudge needs to know which day it is, and day 0 is the day
    /// the trial started rather than the first whole day after it.
    func testDayIndexCountsFromTheStart() {
        XCTAssertEqual(active(daysLeft: 7).trial.dayIndex(now: now), 0)
        XCTAssertEqual(active(daysLeft: 3).trial.dayIndex(now: now), 4)
    }

    // MARK: - What a trial opens

    func testATrialOpensEveryLength() {
        XCTAssertEqual(EntitlementRules.availableWindows(active()), TimeWindow.allCases)
        for window in TimeWindow.allCases {
            XCTAssertEqual(
                EntitlementRules.canStartLesson(active(), window: window, now: now),
                .allowed,
                "\(window) should be open during a trial"
            )
        }
    }

    func testATrialIncludesTheTestAndGoingDeeper() {
        XCTAssertEqual(EntitlementRules.canTakePostLessonTest(active()), .allowed)
        XCTAssertEqual(EntitlementRules.canGoDeeper(active()), .allowed)
    }

    /// A trialist is premium for gating purposes, so the free daily counter
    /// must not move under them. Their spending is counted on the server,
    /// against the trial's own ten.
    func testATrialDoesNotSpendTheFreeDailyAllowance() {
        let before = active()
        XCTAssertEqual(EntitlementRules.consumingLesson(before, now: now), before)
    }

    // MARK: - The two ceilings

    func testTheLastTrialLessonIsAllowedAndTheNextIsNot() {
        XCTAssertEqual(
            EntitlementRules.canStartLesson(active(lessons: 1), window: .fifteen, now: now),
            .allowed
        )
        XCTAssertEqual(
            EntitlementRules.canStartLesson(active(lessons: 0), window: .fifteen, now: now),
            .denied(.trialEnded)
        )
    }

    /// Spending both course slots is not the trial ending, and must not be
    /// reported as it. The reader still has lessons and most of a week.
    func testSpendingBothCoursesIsACapAndNotAPaywall() {
        let snapshot = active(lessons: 6, courses: 0)
        let decision = EntitlementRules.canStartLesson(snapshot, window: .thirty, now: now)

        XCTAssertEqual(decision, .capped(.trialCoursesThisWeek(used: 2, cap: 2)))
        // The distinction that matters at the call site: a capped decision
        // carries no paywall trigger, so "show the paywall for any denial"
        // cannot reach it.
        XCTAssertNil(decision.trigger)

        XCTAssertEqual(
            EntitlementRules.canStartLesson(snapshot, window: .seven, now: now),
            .allowed,
            "the shorter lengths still work"
        )
    }

    /// Lessons running out beats courses running out: the trial is over, and
    /// a course cap message would tell somebody the shorter lengths still
    /// work when nothing does.
    func testAnExhaustedTrialReportsTheTrialAndNotTheCourseCap() {
        XCTAssertEqual(
            EntitlementRules.canStartLesson(active(lessons: 0, courses: 0), window: .thirty, now: now),
            .denied(.trialEnded)
        )
    }

    // MARK: - The stub

    func testTheStubGrantsExactlyOneTrial() async throws {
        // Every await is hoisted out of the XCTest call. `XCTUnwrap` and the
        // `XCTAssert*` family all take autoclosures, and an autoclosure cannot
        // carry an await.
        let store = StubTrialStore()
        let firstResult = await store.start()
        let first = try XCTUnwrap(firstResult)
        XCTAssertTrue(first.started)
        XCTAssertEqual(first.trial.remainingLessons, TrialLimits.lessons)
        XCTAssertEqual(first.trial.remainingCourses, TrialLimits.courses)

        // Non-nil: a refusal is an answer. Only an unreachable store is nil.
        let secondResult = await store.start()
        let second = try XCTUnwrap(secondResult)
        XCTAssertFalse(second.started)
        XCTAssertEqual(second.reason, "alreadyUsed")
        XCTAssertEqual(second.trial.startedAt, first.trial.startedAt)
    }

    func testTheStubCanBeginPartWayThroughAWeek() async throws {
        let store = StubTrialStore(
            TrialMirror(status: .active, remainingLessons: 4, remainingCourses: 1)
        )
        let refusedResult = await store.start()
        let refused = try XCTUnwrap(refusedResult)
        XCTAssertFalse(refused.started, "a running trial cannot be started again")
        let statusResult = await store.status()
        let status = try XCTUnwrap(statusResult)
        XCTAssertEqual(status.remainingLessons, 4)
    }

    /// The numbers the copy states have to be the numbers the server enforces.
    /// These are the mirror of `TRIAL_LESSONS` / `TRIAL_COURSES` /
    /// `TRIAL_DAYS` in `server/src/limits.ts`.
    func testTheAdvertisedLimitsMatchTheServer() {
        XCTAssertEqual(TrialLimits.lessons, 10)
        XCTAssertEqual(TrialLimits.courses, 2)
        XCTAssertEqual(TrialLimits.days, 7)
        XCTAssertEqual(TrialLimits.duration, 7 * 86_400)
    }
}
