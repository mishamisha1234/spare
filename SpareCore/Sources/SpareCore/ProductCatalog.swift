import Foundation

/// What a user can buy. Three options, no tiers-within-tiers: every one of
/// these grants exactly the same premium access, they differ only in how
/// it's paid for.
public enum PurchaseProductKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case monthly
    case yearly
    case lifetime

    public var id: String { rawValue }

    /// The entitlement tier this purchase grants.
    public var tier: Tier {
        switch self {
        case .monthly: .monthly
        case .yearly: .yearly
        case .lifetime: .lifetime
        }
    }

    /// True for the auto-renewing subscriptions, false for the one-off buy.
    /// Drives whether "cancel anytime" applies.
    public var isSubscription: Bool { self != .lifetime }
}

/// Product identifiers, and the mapping from a purchased identifier back to
/// the tier it grants.
///
/// Lives in SpareCore rather than beside the StoreKit code so the mapping is
/// testable on Linux: getting `lifetime` wrong here would silently hand a
/// paying customer the wrong entitlement, which is exactly the kind of thing
/// that should not depend on a Mac to verify.
public enum ProductCatalog {
    public static let monthlyID = "app.spare.premium.monthly"
    public static let yearlyID = "app.spare.premium.yearly"
    public static let lifetimeID = "app.spare.premium.lifetime"

    /// Every identifier the app asks StoreKit to load.
    public static let allIDs: [String] = [monthlyID, yearlyID, lifetimeID]

    public static func kind(forProductID id: String) -> PurchaseProductKind? {
        switch id {
        case monthlyID: .monthly
        case yearlyID: .yearly
        case lifetimeID: .lifetime
        default: nil
        }
    }

    public static func productID(for kind: PurchaseProductKind) -> String {
        switch kind {
        case .monthly: monthlyID
        case .yearly: yearlyID
        case .lifetime: lifetimeID
        }
    }

    /// The tier granted by an owned product identifier. `nil` for anything
    /// unrecognised, which is treated as granting nothing.
    public static func tier(forProductID id: String) -> Tier? {
        kind(forProductID: id)?.tier
    }

    /// The strongest tier implied by a set of owned product identifiers.
    ///
    /// Someone can legitimately hold more than one: a lifetime buyer who
    /// previously subscribed still has that subscription in
    /// `currentEntitlements` until it lapses. Lifetime wins, then yearly,
    /// then monthly.
    public static func resolvedTier(forOwnedProductIDs ids: some Sequence<String>) -> Tier {
        var best = Tier.free
        for id in ids {
            guard let tier = tier(forProductID: id) else { continue }
            if rank(tier) > rank(best) { best = tier }
        }
        return best
    }

    private static func rank(_ tier: Tier) -> Int {
        switch tier {
        case .free: 0
        case .monthly: 1
        case .yearly: 2
        case .lifetime: 3
        }
    }
}

/// A purchasable product, flattened out of StoreKit into a value type so the
/// paywall can be built and tested without StoreKit present.
public struct PurchaseProduct: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: PurchaseProductKind
    public var displayName: String
    /// Already localized by StoreKit — never assembled from `price` by hand.
    public var displayPrice: String
    public var price: Decimal

    public init(
        id: String,
        kind: PurchaseProductKind,
        displayName: String,
        displayPrice: String,
        price: Decimal
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.price = price
    }
}

/// The arithmetic behind "£X/month, save Y%" on the yearly option.
///
/// Pure and separately tested because it is a claim about money: an
/// overstated saving is a false advertisement, not a rounding bug.
///
/// Rounding goes through a formatted-string round-trip rather than
/// `NSDecimalRound`. That looks roundabout, and it is deliberate: a `Decimal`
/// built from a float literal carries the binary error of the `Double` it
/// passed through, and rounding such a value in place left results like
/// `4.990000000000001024` — visibly not the "2dp" the signature promises.
/// Formatting to a fixed 2dp string and parsing it back yields an exact
/// decimal on every platform.
public enum PricingSummary {

    /// The yearly price expressed per month, exact to 2dp.
    public static func perMonth(yearly: Decimal) -> Decimal {
        let monthly = double(yearly) / 12
        return exactTwoPlaces(monthly) ?? yearly
    }

    /// Whole-percent saving of the yearly plan against 12x the monthly price.
    ///
    /// Returns `nil` when there is nothing honest to claim: no monthly price
    /// to compare against, a non-positive baseline, or a yearly plan that
    /// isn't actually cheaper. Deliberately rounds *down*, so the number
    /// shown is never larger than the real saving.
    public static func savingPercent(yearly: Decimal, monthly: Decimal) -> Int? {
        guard monthly > 0 else { return nil }
        let twelveMonths = double(monthly) * 12
        let yearlyValue = double(yearly)
        guard yearlyValue < twelveMonths, twelveMonths > 0 else { return nil }

        let percent = ((twelveMonths - yearlyValue) / twelveMonths) * 100
        // Scrub float dust before flooring, so a saving that is exactly 33%
        // can't land as 32 because the division came back 32.999999999999996.
        let cleaned = (percent * 1e6).rounded() / 1e6
        let floored = Int(cleaned.rounded(.down))
        return floored > 0 ? floored : nil
    }

    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    private static func exactTwoPlaces(_ value: Double) -> Decimal? {
        Decimal(string: String(format: "%.2f", value))
    }
}
