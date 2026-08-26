import Foundation

/// What a user can buy. Two options, no tiers-within-tiers: both grant
/// exactly the same premium access, they differ only in how it's paid for.
///
/// There was a lifetime product. It is gone deliberately: a one-time payment
/// against a permanent per-use inference cost is a liability that compounds
/// forever and cannot be unwound. If a no-subscription option is wanted later
/// it should be a bounded credit pack, not unlimited access.
public enum PurchaseProductKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case monthly
    case yearly

    public var id: String { rawValue }

    /// The entitlement tier this purchase grants.
    public var tier: Tier {
        switch self {
        case .monthly: .monthly
        case .yearly: .yearly
        }
    }
}

/// Product identifiers, and the mapping from a purchased identifier back to
/// the tier it grants.
///
/// Lives in SpareCore rather than beside the StoreKit code so the mapping is
/// testable on Linux: getting one wrong here would silently hand a paying
/// customer the wrong entitlement, which is exactly the kind of thing that
/// should not depend on a Mac to verify.
public enum ProductCatalog {
    public static let monthlyID = "app.spare.premium.monthly"
    public static let yearlyID = "app.spare.premium.yearly"

    /// The withdrawn lifetime product.
    ///
    /// Kept only so a stored entitlement written before it was withdrawn is
    /// still recognised rather than decoding to nothing. It is not in
    /// `allIDs`, so StoreKit is never asked for it and it can never be bought
    /// again.
    public static let retiredLifetimeID = "app.spare.premium.lifetime"

    /// Every identifier the app asks StoreKit to load.
    public static let allIDs: [String] = [monthlyID, yearlyID]

    public static func kind(forProductID id: String) -> PurchaseProductKind? {
        switch id {
        case monthlyID: .monthly
        case yearlyID: .yearly
        default: nil
        }
    }

    public static func productID(for kind: PurchaseProductKind) -> String {
        switch kind {
        case .monthly: monthlyID
        case .yearly: yearlyID
        }
    }

    /// The tier granted by an owned product identifier. `nil` for anything
    /// unrecognised, which is treated as granting nothing.
    ///
    /// The retired lifetime identifier still resolves, to `.yearly`. Nobody
    /// holds one in production -- it never shipped -- but a local StoreKit
    /// configuration on a development Mac can have granted one, and silently
    /// downgrading a held entitlement to free is a worse failure than
    /// honouring a product we no longer sell.
    public static func tier(forProductID id: String) -> Tier? {
        if id == retiredLifetimeID { return .yearly }
        return kind(forProductID: id)?.tier
    }

    /// The strongest tier implied by a set of owned product identifiers.
    ///
    /// Someone can legitimately hold more than one: an annual subscriber who
    /// previously paid monthly still has that transaction in
    /// `currentEntitlements` until it lapses. Yearly wins, then monthly.
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
        // No product grants a trial, so `.trialing` never reaches this
        // function. Ranked with free rather than left to a default, so that
        // if it ever did arrive here a real purchase would still win.
        case .free, .trialing: 0
        case .monthly: 1
        case .yearly: 2
        }
    }
}

/// A reduced price for the first billing period of a subscription.
///
/// Its presence means *this account can actually have it*. StoreKit's
/// introductory offer is a property of the product, but eligibility is a
/// property of the Apple Account: somebody who has subscribed before is
/// shown the standard price no matter what the product carries. Modelling
/// eligibility as absence rather than as a separate flag is deliberate —
/// there is then no way for a view to display an offer it forgot to check,
/// because an ineligible reader has nothing to display.
public struct IntroductoryOffer: Sendable, Equatable {
    /// Already localized by StoreKit — never assembled from `price` by hand.
    public var displayPrice: String
    public var price: Decimal

    public init(displayPrice: String, price: Decimal) {
        self.displayPrice = displayPrice
        self.price = price
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
    /// The first-period price, when the product has one *and* this account
    /// is eligible for it. See ``IntroductoryOffer``.
    public var introductoryOffer: IntroductoryOffer?

    public init(
        id: String,
        kind: PurchaseProductKind,
        displayName: String,
        displayPrice: String,
        price: Decimal,
        introductoryOffer: IntroductoryOffer? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.displayPrice = displayPrice
        self.price = price
        self.introductoryOffer = introductoryOffer
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

    /// Whole-percent discount of an introductory price against the price it
    /// reverts to.
    ///
    /// Separate from ``savingPercent(yearly:monthly:)`` and never combined
    /// with it. The annual saving is a claim about annual versus monthly
    /// billing; this is a claim about year one versus year two. Multiplying
    /// them together would produce a number larger than either discount
    /// actually is, which is the specific way a truthful pair of prices
    /// becomes a false advertisement.
    ///
    /// Rounds down, and returns `nil` when there is nothing honest to claim.
    public static func introductorySavingPercent(
        introductory: Decimal,
        standard: Decimal
    ) -> Int? {
        let standardValue = double(standard)
        let introValue = double(introductory)
        guard standardValue > 0, introValue >= 0, introValue < standardValue else { return nil }

        let percent = ((standardValue - introValue) / standardValue) * 100
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
