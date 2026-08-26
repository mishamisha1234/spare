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
            tier: .trialing, trial: trial(lessons: 6, courses: 1), miniCoursesRemaining: 0
        )

        XCTAssertTrue(copy.contains("6 of \(TrialLimits.lessons) trial lessons left"), copy)
        XCTAssertTrue(copy.contains("1 of \(TrialLimits.courses) mini-courses"), copy)
    }

    /// "No card" is the other half of the offer and has to survive here too:
    /// somebody who thinks they have entered a paid trial will go looking for
    /// somewhere to cancel it, find nothing, and assume the worst.
    func testTheTrialLineSaysThereIsNothingToCancel() {
        let copy = SettingsView
            .planDetail(tier: .trialing, trial: trial(lessons: 3, courses: 0), miniCoursesRemaining: 0)
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
            miniCoursesRemaining: 0
        )
        XCTAssertTrue(copy.contains("\(TrialLimits.lessons) of \(TrialLimits.lessons)"), copy)
        XCTAssertTrue(copy.contains("\(TrialLimits.courses) of \(TrialLimits.courses)"), copy)
    }

    /// A trialist must not be shown the subscriber's monthly allowance. It is
    /// a different cap with a different number, and there is no month.
    func testATrialistIsNotShownTheSubscriberAllowance() {
        let copy = SettingsView.planDetail(
            tier: .trialing, trial: trial(lessons: 4, courses: 1), miniCoursesRemaining: 11
        )
        XCTAssertFalse(copy.contains("this month"), copy)
        XCTAssertFalse(copy.contains("11"), copy)
    }

    func testTheFreeLineStillPromisesTheWholeLibrary() {
        let copy = SettingsView.planDetail(
            tier: .free, trial: .eligible, miniCoursesRemaining: 0
        )
        XCTAssertTrue(copy.lowercased().contains("whole library"), copy)
        XCTAssertTrue(copy.contains("one lesson a day"), copy)
    }

    /// No hedging, on any of the three. A disclosure that says "up to" or
    /// "roughly" is one written around a limit somebody was not confident in.
    func testNoPlanLineHedges() {
        for tier in Tier.allCases {
            let copy = SettingsView
                .planDetail(tier: tier, trial: trial(lessons: 5, courses: 1), miniCoursesRemaining: 7)
                .lowercased()
            for weasel in ["up to", "usually", "typically", "roughly", "about"] {
                XCTAssertFalse(copy.contains(weasel), "\(tier) hedged with \"\(weasel)\": \(copy)")
            }
        }
    }
}
