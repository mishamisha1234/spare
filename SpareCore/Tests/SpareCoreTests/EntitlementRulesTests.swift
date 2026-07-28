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
            EntitlementRules.canStartLesson(spent, window: .ten, now: now, calendar: calendar),
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
            EntitlementRules.canStartLesson(fresh, window: .fortyFive, now: now, calendar: calendar),
            .denied(.lockedWindow(.fortyFive))
        )
    }

    func testLockedWindowIsReportedAheadOfDailyLimit() {
        // Both reasons apply; the window lock is the more explicable one.
        let used = EntitlementSnapshot(tier: .free, freeLessonsUsedToday: 1, lastFreeLessonDate: now)
        XCTAssertEqual(
            EntitlementRules.canStartLesson(used, window: .fortyFive, now: now, calendar: calendar),
            .denied(.lockedWindow(.fortyFive))
        )
    }

    func testAvailableWindowsByTier() {
        XCTAssertEqual(EntitlementRules.availableWindows(.free), [.three, .ten])
        XCTAssertEqual(EntitlementRules.availableWindows(.premium), TimeWindow.allCases)
    }

    func testBrowsingLockedWindowIsDeniedButStartingIsTheRealGate() {
        XCTAssertEqual(
            EntitlementRules.canBrowseSuggestions(.free, window: .three),
            .allowed
        )
        XCTAssertEqual(
            EntitlementRules.canBrowseSuggestions(.free, window: .fortyFive),
            .denied(.lockedWindow(.fortyFive))
        )
        XCTAssertEqual(
            EntitlementRules.canBrowseSuggestions(.premium, window: .fortyFive),
            .allowed
        )
    }

    // MARK: - Premium

    func testEveryPaidTierIsUnlimited() {
        for tier in [Tier.monthly, .yearly, .lifetime] {
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
        let premium = EntitlementSnapshot(tier: .lifetime, freeLessonsUsedToday: 0, lastFreeLessonDate: .distantPast)
        XCTAssertEqual(EntitlementRules.consumingLesson(premium, now: now, calendar: calendar), premium)
    }

    func testFreeUserCannotGoDeeper() {
        XCTAssertEqual(EntitlementRules.canGoDeeper(.free), .denied(.goDeeperLocked))
    }

    func testApplyingAPurchaseSetsTheTier() {
        let upgraded = EntitlementRules.applying(tier: .yearly, to: .free)
        XCTAssertEqual(upgraded.tier, .yearly)
        XCTAssertTrue(upgraded.tier.isPremium)
    }

    // MARK: - Library cap

    func testFreeLibraryIsCappedAtTen() {
        XCTAssertEqual(EntitlementRules.visibleLibraryCount(.free, totalEntries: 47), 10)
        XCTAssertEqual(EntitlementRules.hiddenLibraryCount(.free, totalEntries: 47), 37)
    }

    func testFreeLibraryBelowCapShowsEverything() {
        XCTAssertEqual(EntitlementRules.visibleLibraryCount(.free, totalEntries: 4), 4)
        XCTAssertEqual(EntitlementRules.hiddenLibraryCount(.free, totalEntries: 4), 0)
    }

    func testPremiumLibraryIsUncapped() {
        XCTAssertEqual(EntitlementRules.visibleLibraryCount(.premium, totalEntries: 470), 470)
        XCTAssertEqual(EntitlementRules.hiddenLibraryCount(.premium, totalEntries: 470), 0)
    }

    func testEmptyLibrary() {
        XCTAssertEqual(EntitlementRules.visibleLibraryCount(.free, totalEntries: 0), 0)
        XCTAssertEqual(EntitlementRules.hiddenLibraryCount(.free, totalEntries: 0), 0)
    }

    // MARK: - Decision helpers

    func testDecisionAccessors() {
        XCTAssertTrue(AccessDecision.allowed.isAllowed)
        XCTAssertNil(AccessDecision.allowed.trigger)
        let denied = AccessDecision.denied(.dailyLimitReached)
        XCTAssertFalse(denied.isAllowed)
        XCTAssertEqual(denied.trigger, .dailyLimitReached)
    }

    func testSnapshotCodableRoundTrip() throws {
        let snapshot = EntitlementSnapshot(tier: .yearly, freeLessonsUsedToday: 3, lastFreeLessonDate: now)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(EntitlementSnapshot.self, from: data), snapshot)
    }
}
