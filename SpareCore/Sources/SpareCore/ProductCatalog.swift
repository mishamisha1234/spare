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
public enum PricingSummary {

    /// The yearly price expressed per month, rounded to 2dp.
    public static func perMonth(yearly: Decimal) -> Decimal {
        var result = yearly / 12
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 2, .plain)
        return rounded
    }

    /// Whole-percent saving of the yearly plan against 12x the monthly price.
    ///
    /// Returns `nil` when there is nothing honest to claim: no monthly price
    /// to compare against, a non-positive baseline, or a yearly plan that
    /// isn't actually cheaper. Deliberately rounds *down*, so the number
    /// shown is never larger than the real saving.
    public static func savingPercent(yearly: Decimal, monthly: Decimal) -> Int? {
        guard monthly > 0 else { return nil }
        let twelveMonths = monthly * 12
        guard yearly < twelveMonths else { return nil }

        let saved = twelveMonths - yearly
        let fraction = (saved / twelveMonths) * 100
        var rounded = Decimal()
        var mutable = fraction
        NSDecimalRound(&rounded, &mutable, 0, .down)

        let percent = NSDecimalNumber(decimal: rounded).intValue
        return percent > 0 ? percent : nil
    }
}
