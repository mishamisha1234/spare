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
        // The case the split exists for. Premium access, no transaction.
        .trialing: (access: true, paying: false),
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

    /// Exactly one tier grants access with no purchase behind it.
    ///
    /// This assertion used to say *none*, and was written to fail the day one
    /// arrived — which is what it did. Naming the tier rather than counting
    /// them means a second one cannot be added without somebody re-reading
    /// every `isPaying` call site, which is the whole point of the split.
    func testOnlyTheTrialGrantsAccessWithoutPayment() {
        let accessWithoutPayment = Tier.allCases.filter { $0.hasPremiumAccess && !$0.isPaying }
        XCTAssertEqual(accessWithoutPayment, [.trialing])
    }

    /// The single line that keeps the global spend ceiling meaningful. A
    /// trialist's requests are not funded by anything, so they stop at the
    /// ceiling exactly like a free device does.
    func testATrialDoesNotPassTheSpendCeiling() {
        XCTAssertFalse(Tier.trialing.isPaying)
        XCTAssertTrue(Tier.trialing.hasPremiumAccess)
    }
}
