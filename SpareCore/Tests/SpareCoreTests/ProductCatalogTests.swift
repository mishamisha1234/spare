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
            XCTAssertTrue(kind.tier.isPremium, "\(kind) must grant premium")
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

    func testPerMonthDividesTheYearlyPrice() {
        XCTAssertEqual(PricingSummary.perMonth(yearly: 24), 2)
        XCTAssertEqual(PricingSummary.perMonth(yearly: 59.88), 4.99)
    }

    func testPerMonthRoundsToTwoPlaces() {
        // 49.99 / 12 = 4.16583...
        XCTAssertEqual(PricingSummary.perMonth(yearly: 49.99), 4.17)
    }

    func testSavingPercentAgainstTwelveMonthlyPayments() {
        // 12 x 4.99 = 59.88; 39.99 saves 33.2% -> 33 rounded down.
        XCTAssertEqual(PricingSummary.savingPercent(yearly: 39.99, monthly: 4.99), 33)
    }

    /// Rounding *down* is the whole point: the advertised saving must never
    /// exceed the real one.
    func testSavingPercentRoundsDownNotToNearest() {
        // 12 x 1.00 = 12.00; 8.05 saves 32.9%, which must not read as 33%.
        XCTAssertEqual(PricingSummary.savingPercent(yearly: 8.05, monthly: 1.00), 32)
    }

    func testNoSavingClaimedWhenYearlyIsNotCheaper() {
        XCTAssertNil(PricingSummary.savingPercent(yearly: 59.88, monthly: 4.99), "identical cost")
        XCTAssertNil(PricingSummary.savingPercent(yearly: 79.99, monthly: 4.99), "yearly is worse")
    }

    func testNoSavingClaimedWithoutAMonthlyBaseline() {
        XCTAssertNil(PricingSummary.savingPercent(yearly: 39.99, monthly: 0))
        XCTAssertNil(PricingSummary.savingPercent(yearly: 39.99, monthly: -1))
    }

    func testSavingBelowOnePercentIsNotClaimedAtAll() {
        // 12 x 10 = 120; 119.5 is a 0.4% saving -> nothing worth a badge.
        XCTAssertNil(PricingSummary.savingPercent(yearly: 119.5, monthly: 10))
    }
}
