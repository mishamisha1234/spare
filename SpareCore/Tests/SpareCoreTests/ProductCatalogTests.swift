import XCTest
@testable import SpareCore

final class ProductCatalogTests: XCTestCase {

    // MARK: - Identifier mapping

    func testEveryKindRoundTripsThroughItsProductID() {
        for kind in PurchaseProductKind.allCases {
            let id = ProductCatalog.productID(for: kind)
            XCTAssertEqual(ProductCatalog.kind(forProductID: id), kind)
            XCTAssertEqual(ProductCatalog.tier(forProductID: id), kind.tier)
        }
    }

    func testAllIDsCoversEveryKindExactlyOnce() {
        XCTAssertEqual(ProductCatalog.allIDs.count, PurchaseProductKind.allCases.count)
        XCTAssertEqual(Set(ProductCatalog.allIDs).count, ProductCatalog.allIDs.count)
        for kind in PurchaseProductKind.allCases {
            XCTAssertTrue(ProductCatalog.allIDs.contains(ProductCatalog.productID(for: kind)))
        }
    }

    func testEveryPurchasedTierIsPremium() {
        for kind in PurchaseProductKind.allCases {
            XCTAssertTrue(kind.tier.isPaying, "\(kind) must be a tier with a purchase behind it")
            XCTAssertTrue(kind.tier.hasPremiumAccess, "\(kind) must grant premium access")
        }
    }

    func testUnknownProductIDGrantsNothing() {
        XCTAssertNil(ProductCatalog.kind(forProductID: "app.spare.premium.weekly"))
        XCTAssertNil(ProductCatalog.tier(forProductID: ""))
        XCTAssertEqual(ProductCatalog.resolvedTier(forOwnedProductIDs: ["nonsense"]), .free)
    }

    func testOnlyLifetimeIsANonSubscription() {
        XCTAssertTrue(PurchaseProductKind.monthly.isSubscription)
        XCTAssertTrue(PurchaseProductKind.yearly.isSubscription)
        XCTAssertFalse(PurchaseProductKind.lifetime.isSubscription)
    }

    // MARK: - Resolving several owned products at once

    func testNoEntitlementsMeansFree() {
        XCTAssertEqual(ProductCatalog.resolvedTier(forOwnedProductIDs: []), .free)
    }

    /// A lifetime buyer who previously subscribed still has the subscription
    /// in `currentEntitlements` until it lapses. They must not be downgraded.
    func testLifetimeWinsOverAConcurrentSubscription() {
        XCTAssertEqual(
            ProductCatalog.resolvedTier(forOwnedProductIDs: [
                ProductCatalog.monthlyID, ProductCatalog.lifetimeID,
            ]),
            .lifetime
        )
    }

    func testYearlyWinsOverMonthly() {
        XCTAssertEqual(
            ProductCatalog.resolvedTier(forOwnedProductIDs: [
                ProductCatalog.yearlyID, ProductCatalog.monthlyID,
            ]),
            .yearly
        )
    }

    func testUnknownIDsAreIgnoredRatherThanDowngrading() {
        XCTAssertEqual(
            ProductCatalog.resolvedTier(forOwnedProductIDs: ["junk", ProductCatalog.yearlyID]),
            .yearly
        )
    }

    // MARK: - Pricing claims
    //
    // Money is built with `Decimal(string:)` throughout, never a float
    // literal: `Decimal` conforms to ExpressibleByFloatLiteral by way of
    // `Double`, so `4.99` as a literal is really 4.990000000000000213… and
    // an exact-equality assertion against it is testing binary error rather
    // than the arithmetic. This is also how StoreKit supplies prices —
    // `Product.price` is a true decimal, not a converted float.

    private func money(_ string: String) -> Decimal {
        guard let value = Decimal(string: string) else {
            XCTFail("not a decimal: \(string)")
            return 0
        }
        return value
    }

    func testPerMonthDividesTheYearlyPrice() {
        XCTAssertEqual(PricingSummary.perMonth(yearly: money("24")), money("2"))
        XCTAssertEqual(PricingSummary.perMonth(yearly: money("59.88")), money("4.99"))
    }

    func testPerMonthIsExactToTwoPlaces() {
        // 49.99 / 12 = 4.16583...
        let result = PricingSummary.perMonth(yearly: money("49.99"))
        XCTAssertEqual(result, money("4.17"))
        // Guards the actual defect this caught: rounding that leaves a value
        // like 4.990000000000001024 satisfies neither the contract nor a
        // price label.
        XCTAssertEqual("\(result)", "4.17", "must be exactly 2dp, not merely close")
    }

    func testPerMonthSurvivesAPriceThatIsNotCleanlyDivisible() {
        // 100 / 12 = 8.3333...
        XCTAssertEqual(PricingSummary.perMonth(yearly: money("100")), money("8.33"))
    }

    func testSavingPercentAgainstTwelveMonthlyPayments() {
        // 12 x 4.99 = 59.88; 39.99 saves 33.2% -> 33 rounded down.
        XCTAssertEqual(
            PricingSummary.savingPercent(yearly: money("39.99"), monthly: money("4.99")),
            33
        )
    }

    /// Rounding *down* is the whole point: the advertised saving must never
    /// exceed the real one.
    func testSavingPercentRoundsDownNotToNearest() {
        // 12 x 1.00 = 12.00; 8.05 saves 32.9%, which must not read as 33%.
        XCTAssertEqual(
            PricingSummary.savingPercent(yearly: money("8.05"), monthly: money("1.00")),
            32
        )
    }

    /// An exactly-round saving must not be dragged down to 49 by float dust
    /// in the division.
    func testExactlyHalfPriceReadsAsFiftyPercent() {
        XCTAssertEqual(
            PricingSummary.savingPercent(yearly: money("60"), monthly: money("10")),
            50
        )
    }

    func testNoSavingClaimedWhenYearlyIsNotCheaper() {
        XCTAssertNil(
            PricingSummary.savingPercent(yearly: money("59.88"), monthly: money("4.99")),
            "identical cost"
        )
        XCTAssertNil(
            PricingSummary.savingPercent(yearly: money("79.99"), monthly: money("4.99")),
            "yearly is worse"
        )
    }

    func testNoSavingClaimedWithoutAMonthlyBaseline() {
        XCTAssertNil(PricingSummary.savingPercent(yearly: money("39.99"), monthly: 0))
        XCTAssertNil(PricingSummary.savingPercent(yearly: money("39.99"), monthly: money("-1")))
    }

    func testSavingBelowOnePercentIsNotClaimedAtAll() {
        // 12 x 10 = 120; 119.5 is a 0.4% saving -> nothing worth a badge.
        XCTAssertNil(PricingSummary.savingPercent(yearly: money("119.5"), monthly: money("10")))
    }
}
