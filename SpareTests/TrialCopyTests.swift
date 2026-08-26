import XCTest
import SpareCore
@testable import Spare

/// The trial's cap is disclosed, and these are what make that a fact rather
/// than an intention.
///
/// A cap the reader only discovers by hitting it is the App Review problem
/// this project already fixed once, on the free tier's daily limit. The trial
/// hands out Opus, so the same sentence has to be true here and has to keep
/// being true when the numbers move.
final class TrialCopyTests: XCTestCase {

    private func trial(lessons: Int, courses: Int) -> TrialMirror {
        TrialMirror(
            status: .active,
            remainingLessons: lessons,
            remainingCourses: courses,
            startedAt: Date(),
            expiresAt: Date().addingTimeInterval(3 * 86_400)
        )
    }

    /// Three plans, three names. A trialist shown "Premium" would be told
    /// they have a subscription they have not bought, and would look for a
    /// cancel button that does not exist.
    func testEveryTierHasItsOwnName() {
        XCTAssertEqual(SettingsView.planName(for: .free), "Free")
        XCTAssertEqual(SettingsView.planName(for: .trialing), "Premium trial")
        XCTAssertEqual(SettingsView.planName(for: .monthly), "Premium")
        XCTAssertEqual(SettingsView.planName(for: .yearly), "Premium")

        let names = Set(Tier.allCases.map { SettingsView.planName(for: $0) })
        XCTAssertEqual(names.count, 3, "a tier was added without deciding what to call it")
    }

    func testTheTrialLineStatesBothCaps() {
        let copy = SettingsView.planDetail(
            tier: .trialing, trial: trial(lessons: 6, courses: 1), allowance: .unknown
        )

        XCTAssertTrue(copy.contains("6 of \(TrialLimits.lessons) trial lessons left"), copy)
        XCTAssertTrue(copy.contains("1 of \(TrialLimits.courses) mini-courses"), copy)
    }

    /// "No card" is the other half of the offer and has to survive here too:
    /// somebody who thinks they have entered a paid trial will go looking for
    /// somewhere to cancel it, find nothing, and assume the worst.
    func testTheTrialLineSaysThereIsNothingToCancel() {
        let copy = SettingsView
            .planDetail(tier: .trialing, trial: trial(lessons: 3, courses: 0), allowance: .unknown)
            .lowercased()
        XCTAssertTrue(copy.contains("no card"), copy)
        XCTAssertTrue(copy.contains("nothing to cancel"), copy)
    }

    /// The numbers come from the limits, not from the sentence. A cap change
    /// that the copy did not follow is the failure this catches.
    func testTheCapsAreNotHardcodedIntoTheSentence() {
        let copy = SettingsView.planDetail(
            tier: .trialing,
            trial: trial(lessons: TrialLimits.lessons, courses: TrialLimits.courses),
            allowance: .unknown
        )
        XCTAssertTrue(copy.contains("\(TrialLimits.lessons) of \(TrialLimits.lessons)"), copy)
        XCTAssertTrue(copy.contains("\(TrialLimits.courses) of \(TrialLimits.courses)"), copy)
    }

    /// A trialist must not be shown the subscriber's monthly allowance. It is
    /// a different cap with a different number, and there is no month.
    func testATrialistIsNotShownTheSubscriberAllowance() {
        let copy = SettingsView.planDetail(
            tier: .trialing,
            trial: trial(lessons: 4, courses: 1),
            allowance: .known(AllowanceMirror(
                trial: trial(lessons: 4, courses: 1),
                premium: PremiumAllowance(lessonsRemaining: 11, coursesRemaining: 3)
            ))
        )
        XCTAssertFalse(copy.contains("this month"), copy)
        XCTAssertFalse(copy.contains("11"), copy)
    }

    // MARK: - The subscriber's month

    private func subscriber(lessons: Int, courses: Int) -> AllowanceState {
        .known(AllowanceMirror(
            trial: .eligible,
            premium: PremiumAllowance(lessonsRemaining: lessons, coursesRemaining: courses)
        ))
    }

    func testTheSubscriberLineStatesBothCapsAndBothCounts() {
        let copy = SettingsView.planDetail(
            tier: .yearly, trial: .eligible, allowance: subscriber(lessons: 38, courses: 6)
        )
        XCTAssertTrue(
            copy.contains("38 of \(EntitlementRules.premiumLessonsPerMonth) lessons left"), copy
        )
        XCTAssertTrue(
            copy.contains("6 of \(EntitlementRules.premiumMiniCoursesPerMonth) mini-courses"), copy
        )
        XCTAssertTrue(copy.contains("Resets on the 1st"), copy)
    }

    /// A failed read is not an answer, so no count is shown. The *fact* that
    /// it failed is an answer, and it is the one the reader can act on.
    func testAnUnreadableAllowanceStatesTheCapsAndSaysWhyThereIsNoCount() {
        let copy = SettingsView.planDetail(tier: .yearly, trial: .eligible, allowance: .unavailable)

        XCTAssertTrue(copy.contains("\(EntitlementRules.premiumLessonsPerMonth) lessons a month"), copy)
        XCTAssertTrue(copy.contains("check your connection"), copy)
        XCTAssertFalse(copy.contains("left this month"), copy)
        XCTAssertFalse(copy.contains("0 of"), "a failed read must never render as zero: \(copy)")
    }

    /// The ordinary first second of a launch. Saying "check your connection"
    /// here would be a false alarm for every reader, every time.
    func testNotHavingAskedYetIsNotAnError() {
        let copy = SettingsView.planDetail(tier: .yearly, trial: .eligible, allowance: .unknown)

        XCTAssertTrue(copy.contains("\(EntitlementRules.premiumLessonsPerMonth) lessons a month"), copy)
        XCTAssertFalse(copy.lowercased().contains("connection"), copy)
        XCTAssertFalse(copy.contains("left this month"), copy)
    }

    /// The word is gone from every plan line, because there is nothing
    /// unlimited left to claim.
    func testNoPlanLineClaimsAnythingIsUnlimited() {
        for tier in Tier.allCases {
            for allowance in [AllowanceState.unknown, .unavailable, subscriber(lessons: 5, courses: 1)] {
                let copy = SettingsView
                    .planDetail(tier: tier, trial: trial(lessons: 5, courses: 1), allowance: allowance)
                    .lowercased()
                XCTAssertFalse(copy.contains("unlimited"), "\(tier): \(copy)")
            }
        }
    }

    func testTheFreeLineStillPromisesTheWholeLibrary() {
        let copy = SettingsView.planDetail(
            tier: .free, trial: .eligible, allowance: .unknown
        )
        XCTAssertTrue(copy.lowercased().contains("whole library"), copy)
        XCTAssertTrue(copy.contains("one lesson a day"), copy)
    }

    /// No hedging, on any of the three. A disclosure that says "up to" or
    /// "roughly" is one written around a limit somebody was not confident in.
    func testNoPlanLineHedges() {
        for tier in Tier.allCases {
            let copy = SettingsView
                .planDetail(
                    tier: tier,
                    trial: trial(lessons: 5, courses: 1),
                    allowance: subscriber(lessons: 7, courses: 2)
                )
                .lowercased()
            for weasel in ["up to", "usually", "typically", "roughly", "about"] {
                XCTAssertFalse(copy.contains(weasel), "\(tier) hedged with \"\(weasel)\": \(copy)")
            }
        }
    }
}
