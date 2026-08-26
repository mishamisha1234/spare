import XCTest
@testable import SpareCore

final class EntitlementRulesTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var yesterday: Date { now.addingTimeInterval(-86_400) }

    // MARK: - Free tier: daily limit

    func testFreeUserGetsOneLessonPerDay() {
        let fresh = EntitlementSnapshot.free
        XCTAssertEqual(
            EntitlementRules.canStartLesson(fresh, window: .three, now: now, calendar: calendar),
            .allowed
        )

        let used = EntitlementRules.consumingLesson(fresh, now: now, calendar: calendar)
        XCTAssertEqual(used.freeLessonsUsedToday, 1)
        XCTAssertEqual(
            EntitlementRules.canStartLesson(used, window: .three, now: now, calendar: calendar),
            .denied(.dailyLimitReached)
        )
    }

    func testDailyCountResetsOnANewDay() {
        let spent = EntitlementSnapshot(tier: .free, freeLessonsUsedToday: 1, lastFreeLessonDate: yesterday)
        XCTAssertEqual(EntitlementRules.effectiveLessonsUsedToday(spent, now: now, calendar: calendar), 0)
        XCTAssertEqual(
            EntitlementRules.canStartLesson(spent, window: .seven, now: now, calendar: calendar),
            .allowed
        )
    }

    func testConsumingAfterRolloverRestartsTheCount() {
        let spent = EntitlementSnapshot(tier: .free, freeLessonsUsedToday: 1, lastFreeLessonDate: yesterday)
        let updated = EntitlementRules.consumingLesson(spent, now: now, calendar: calendar)
        XCTAssertEqual(updated.freeLessonsUsedToday, 1, "yesterday's lesson is not spent today")
        XCTAssertEqual(updated.lastFreeLessonDate, now)
    }

    func testNegativeStoredCountIsTreatedAsZero() {
        let corrupt = EntitlementSnapshot(tier: .free, freeLessonsUsedToday: -4, lastFreeLessonDate: now)
        XCTAssertEqual(EntitlementRules.effectiveLessonsUsedToday(corrupt, now: now, calendar: calendar), 0)
        XCTAssertEqual(
            EntitlementRules.canStartLesson(corrupt, window: .three, now: now, calendar: calendar),
            .allowed
        )
    }

    // MARK: - Free tier: locked windows

    func testFreeUserCannotStartLongerWindows() {
        let fresh = EntitlementSnapshot.free
        XCTAssertEqual(
            EntitlementRules.canStartLesson(fresh, window: .fifteen, now: now, calendar: calendar),
            .denied(.lockedWindow(.fifteen))
        )
        XCTAssertEqual(
            EntitlementRules.canStartLesson(fresh, window: .thirty, now: now, calendar: calendar),
            .denied(.lockedWindow(.thirty))
        )
    }

    func testLockedWindowIsReportedAheadOfDailyLimit() {
        // Both reasons apply; the window lock is the more explicable one.
        let used = EntitlementSnapshot(tier: .free, freeLessonsUsedToday: 1, lastFreeLessonDate: now)
        XCTAssertEqual(
            EntitlementRules.canStartLesson(used, window: .thirty, now: now, calendar: calendar),
            .denied(.lockedWindow(.thirty))
        )
    }

    func testAvailableWindowsByTier() {
        XCTAssertEqual(EntitlementRules.availableWindows(.free), [.three, .seven])
        XCTAssertEqual(EntitlementRules.availableWindows(.premium), TimeWindow.allCases)
    }

    func testBrowsingLockedWindowIsDeniedButStartingIsTheRealGate() {
        XCTAssertEqual(
            EntitlementRules.canBrowseSuggestions(.free, window: .three),
            .allowed
        )
        XCTAssertEqual(
            EntitlementRules.canBrowseSuggestions(.free, window: .thirty),
            .denied(.lockedWindow(.thirty))
        )
        XCTAssertEqual(
            EntitlementRules.canBrowseSuggestions(.premium, window: .thirty),
            .allowed
        )
    }

    // MARK: - Premium

    func testEveryPaidTierIsUnlimited() {
        for tier in [Tier.monthly, .yearly] {
            let snapshot = EntitlementSnapshot(tier: tier, freeLessonsUsedToday: 99, lastFreeLessonDate: now)
            for window in TimeWindow.allCases {
                XCTAssertEqual(
                    EntitlementRules.canStartLesson(snapshot, window: window, now: now, calendar: calendar),
                    .allowed,
                    "\(tier) should unlock \(window)"
                )
            }
            XCTAssertEqual(EntitlementRules.canGoDeeper(snapshot), .allowed)
        }
    }

    func testConsumingDoesNotTouchPremiumCounters() {
        let premium = EntitlementSnapshot(tier: .yearly, freeLessonsUsedToday: 0, lastFreeLessonDate: .distantPast)
        XCTAssertEqual(EntitlementRules.consumingLesson(premium, now: now, calendar: calendar), premium)
    }

    func testFreeUserCannotGoDeeper() {
        XCTAssertEqual(EntitlementRules.canGoDeeper(.free), .denied(.goDeeperLocked))
    }

    // MARK: - Post-lesson test

    func testPostLessonTestIsPremiumOnly() {
        XCTAssertEqual(
            EntitlementRules.canTakePostLessonTest(.free),
            .denied(.postLessonTestLocked)
        )
        for tier in [Tier.monthly, .yearly] {
            XCTAssertEqual(
                EntitlementRules.canTakePostLessonTest(EntitlementSnapshot(tier: tier)),
                .allowed
            )
        }
    }

    // MARK: - The subscriber's two monthly caps

    /// Every one of these used to build a list of library dates and let the
    /// rules count them. That derivation is gone: the server counts charges,
    /// the library counts finished rows, and the two drift. The month's
    /// figures now arrive in the snapshot from the same object that will
    /// refuse the request, so these test the *decision* and nothing else.
    private func subscriber(lessons: Int, courses: Int) -> EntitlementSnapshot {
        EntitlementSnapshot(
            tier: .yearly,
            premiumAllowance: PremiumAllowance(lessonsRemaining: lessons, coursesRemaining: courses)
        )
    }

    func testPremiumMiniCoursesAreCappedPerMonth() {
        XCTAssertEqual(
            EntitlementRules.canStartLesson(
                subscriber(lessons: 20, courses: 0), window: .thirty,
                now: now, calendar: calendar
            ),
            .capped(.miniCoursesThisMonth(
                used: EntitlementRules.premiumMiniCoursesPerMonth,
                cap: EntitlementRules.premiumMiniCoursesPerMonth
            ))
        )
    }

    func testPremiumLessonsAreCappedPerMonth() {
        XCTAssertEqual(
            EntitlementRules.canStartLesson(
                subscriber(lessons: 1, courses: 4), window: .fifteen,
                now: now, calendar: calendar
            ),
            .allowed
        )
        XCTAssertEqual(
            EntitlementRules.canStartLesson(
                subscriber(lessons: 0, courses: 4), window: .fifteen,
                now: now, calendar: calendar
            ),
            .capped(.lessonsThisMonth(
                used: EntitlementRules.premiumLessonsPerMonth,
                cap: EntitlementRules.premiumLessonsPerMonth
            ))
        )
    }

    /// The course ceiling is the more specific refusal and wins where both
    /// apply: "every course this month" explains itself, where "every lesson"
    /// would be wrong about the shorter lengths, which are still open.
    func testTheCourseCapIsReportedBeforeTheLessonCap() {
        XCTAssertEqual(
            EntitlementRules.canStartLesson(
                subscriber(lessons: 0, courses: 0), window: .thirty,
                now: now, calendar: calendar
            ),
            .capped(.miniCoursesThisMonth(
                used: EntitlementRules.premiumMiniCoursesPerMonth,
                cap: EntitlementRules.premiumMiniCoursesPerMonth
            ))
        )
    }

    /// Neither cap is a paywall. A subscriber cannot buy their way past a
    /// fair-use ceiling, so a capped decision must carry no trigger.
    func testHittingEitherCapIsNotAPaywallTrigger() {
        for snapshot in [subscriber(lessons: 20, courses: 0), subscriber(lessons: 0, courses: 4)] {
            let decision = EntitlementRules.canStartLesson(
                snapshot, window: .thirty, now: now, calendar: calendar
            )
            XCTAssertFalse(decision.isAllowed)
            XCTAssertNil(decision.trigger, "a paying user must never be shown the paywall")
            XCTAssertNotNil(decision.cap)
        }
    }

    func testTheCourseCapOnlyAppliesToTheChapteredWindow() {
        let atCourseCap = subscriber(lessons: 20, courses: 0)
        for window in TimeWindow.allCases where !window.format.isChaptered {
            XCTAssertEqual(
                EntitlementRules.canStartLesson(
                    atCourseCap, window: window, now: now, calendar: calendar
                ),
                .allowed,
                "\(window) is not a mini-course and must be unaffected"
            )
        }
    }

    /// No answer from the server means no cap enforced *here*. The server
    /// still enforces it, so the cost of being wrong is a circle that opens
    /// and then refuses -- which is the trade every mirror in this app makes.
    func testNoAllowanceMeansNoLocalCap() {
        let unknown = EntitlementSnapshot(tier: .yearly)
        for window in TimeWindow.allCases {
            XCTAssertEqual(
                EntitlementRules.canStartLesson(unknown, window: window, now: now, calendar: calendar),
                .allowed
            )
        }
    }

    /// The caps are premium-only. A free user asking for a mini-course is
    /// hitting the window lock, and must be told that, not shown a fair-use
    /// message about a plan they don't have.
    func testFreeUserHitsTheWindowLockNotTheCap() {
        XCTAssertEqual(
            EntitlementRules.canStartLesson(.free, window: .thirty, now: now, calendar: calendar),
            .denied(.lockedWindow(.thirty))
        )
    }

    /// The two numbers the copy states have to be the two the server enforces.
    func testTheAdvertisedCapsMatchTheServer() {
        XCTAssertEqual(EntitlementRules.premiumLessonsPerMonth, 50)
        XCTAssertEqual(EntitlementRules.premiumMiniCoursesPerMonth, 8)
    }

    func testApplyingAPurchaseSetsTheTier() {
        let upgraded = EntitlementRules.applying(tier: .yearly, to: .free)
        XCTAssertEqual(upgraded.tier, .yearly)
        XCTAssertTrue(upgraded.tier.hasPremiumAccess)
    }

    // The library cap tests lived here. There is no library cap on any tier
    // now, so there is no function left to assert against -- the rule was
    // deleted rather than relaxed. What replaces them is a copy test: the
    // paywall must not promise a library limit that no longer exists, and
    // must not sell the library back as a premium benefit. See
    // `PaywallCopyTests`.

    // MARK: - Decision helpers

    func testDecisionAccessors() {
        XCTAssertTrue(AccessDecision.allowed.isAllowed)
        XCTAssertNil(AccessDecision.allowed.trigger)
        XCTAssertNil(AccessDecision.allowed.cap)

        let denied = AccessDecision.denied(.dailyLimitReached)
        XCTAssertFalse(denied.isAllowed)
        XCTAssertEqual(denied.trigger, .dailyLimitReached)
        XCTAssertNil(denied.cap, "a paywall denial is not a fair-use cap")

        let capped = AccessDecision.capped(.miniCoursesThisMonth(used: 8, cap: 8))
        XCTAssertFalse(capped.isAllowed)
        XCTAssertNil(capped.trigger, "a fair-use cap must never reach the paywall")
        XCTAssertEqual(capped.cap, .miniCoursesThisMonth(used: 8, cap: 8))
    }

    func testSnapshotCodableRoundTrip() throws {
        let snapshot = EntitlementSnapshot(tier: .yearly, freeLessonsUsedToday: 3, lastFreeLessonDate: now)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(EntitlementSnapshot.self, from: data), snapshot)
    }
}
