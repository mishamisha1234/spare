import XCTest
@testable import SpareCore

/// Pins the two access predicates as an exhaustive table.
///
/// This exists so that adding a tier cannot quietly inherit an answer. The
/// table below has to be edited by hand for a new case, which is the point:
/// `hasPremiumAccess` and `isPaying` are the same today and will not stay
/// that way, and the sites that use them are not interchangeable.
final class TierAccessTests: XCTestCase {

    private let expected: [Tier: (access: Bool, paying: Bool)] = [
        .free: (access: false, paying: false),
        .monthly: (access: true, paying: true),
        .yearly: (access: true, paying: true),
    ]

    func testEveryTierIsAnsweredExplicitly() {
        XCTAssertEqual(
            Set(expected.keys), Set(Tier.allCases),
            "A tier was added or removed without deciding what it grants."
        )
        for tier in Tier.allCases {
            guard let want = expected[tier] else { continue }
            XCTAssertEqual(tier.hasPremiumAccess, want.access, "\(tier).hasPremiumAccess")
            XCTAssertEqual(tier.isPaying, want.paying, "\(tier).isPaying")
        }
    }

    /// Access without payment is the case the split is for. Today nothing
    /// occupies it; the assertion states that as a fact rather than an
    /// oversight, so the day something does, this test names it.
    func testNoTierCurrentlyGrantsAccessWithoutPayment() {
        let accessWithoutPayment = Tier.allCases.filter { $0.hasPremiumAccess && !$0.isPaying }
        XCTAssertEqual(
            accessWithoutPayment, [Tier](),
            "A tier now grants access with no purchase behind it. Every `isPaying` "
                + "call site must be re-read before this test is updated."
        )
    }
}
