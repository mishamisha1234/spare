import Foundation
import StoreKit
import SpareCore

/// The real store. StoreKit 2 only — no receipt parsing, no server.
///
/// `Transaction.currentEntitlements` is the single source of truth for what
/// someone owns: it is already validated by the OS, already excludes expired
/// and refunded purchases, and survives reinstalls without a restore. The
/// locally persisted tier is a cache of that, never the authority.
actor StoreKitPurchaseStore: PurchaseStore {

    /// Products are cached so `purchase` doesn't refetch. StoreKit's
    /// `Product` is Sendable, so holding them across awaits is safe.
    private var cachedProducts: [String: Product] = [:]

    func loadProducts() async throws -> [PurchaseProduct] {
        let products = try await Product.products(for: ProductCatalog.allIDs)
        for product in products {
            cachedProducts[product.id] = product
        }

        var loaded: [PurchaseProduct] = []
        for product in products {
            // An identifier the catalog doesn't recognise would grant an
            // unknown entitlement; drop it rather than guess.
            guard let kind = ProductCatalog.kind(forProductID: product.id) else { continue }
            loaded.append(
                PurchaseProduct(
                    id: product.id,
                    kind: kind,
                    displayName: product.displayName,
                    // StoreKit's own localized string — never assembled from
                    // `price` by hand, which would get currency and locale
                    // wrong in most of the world.
                    displayPrice: product.displayPrice,
                    price: product.price,
                    introductoryOffer: await introductoryOffer(for: product)
                )
            )
        }
        return loaded.sorted { orderIndex($0.kind) < orderIndex($1.kind) }
    }

    /// The first-year price, but only when this Apple Account can actually
    /// have it.
    ///
    /// Both halves are required and neither is optional. `introductoryOffer`
    /// is a property of the product and is present for everybody;
    /// `isEligibleForIntroOffer` is a property of the account, and is false
    /// for anyone who has subscribed in this group before. Quoting "$44.50
    /// for the first year" to somebody who will be charged $89.00 is a false
    /// price — the same class of problem as an undisclosed cap, and one the
    /// App Store rejects for.
    ///
    /// The await is not incidental: eligibility is a network-backed lookup on
    /// the subscription group, which is why this cannot be a plain property
    /// read at the view layer.
    private func introductoryOffer(for product: Product) async -> IntroductoryOffer? {
        guard let subscription = product.subscription,
              let offer = subscription.introductoryOffer,
              await subscription.isEligibleForIntroOffer
        else { return nil }

        return IntroductoryOffer(displayPrice: offer.displayPrice, price: offer.price)
    }

    func purchase(_ kind: PurchaseProductKind) async throws -> PurchaseOutcome {
        let id = ProductCatalog.productID(for: kind)
        let product: Product
        if let cached = cachedProducts[id] {
            product = cached
        } else {
            guard let fetched = try await Product.products(for: [id]).first else {
                throw PurchaseStoreError.productUnavailable
            }
            cachedProducts[id] = fetched
            product = fetched
        }

        switch try await product.purchase() {
        case .success(let verification):
            // `.unverified` means StoreKit could not validate the signature.
            // Treat it as no purchase rather than granting access.
            guard case .verified(let transaction) = verification else {
                throw PurchaseStoreError.unverified
            }
            await transaction.finish()
            return .purchased

        case .userCancelled:
            return .cancelled

        case .pending:
            // Ask to Buy or an SCA step. The transaction may still arrive
            // later through `transactionUpdates()`.
            return .pending

        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    func ownedProductIDs() async -> Set<String> {
        var owned: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            // `currentEntitlements` already filters these out, but stating
            // them makes the rule visible rather than assumed.
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            owned.insert(transaction.productID)
        }
        return owned
    }

    /// The JWS of the current entitlement, for the proxy to verify with Apple.
    ///
    /// Only `.verified` results are considered: an unverified JWS would be
    /// refused by the server anyway, and sending one would turn a local
    /// tampering attempt into a confusing server error rather than a plain
    /// free tier.
    ///
    /// Where several products are owned — an annual bought while a monthly
    /// is still running — the first is enough. Both entitle the same thing,
    /// and the server only needs one transaction to ask Apple about.
    func currentReceipt() async -> String? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.revocationDate != nil { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            return result.jwsRepresentation
        }
        return nil
    }

    /// `nonisolated` so subscribing doesn't need to hop onto the actor —
    /// `Transaction.updates` is a global sequence, not actor state.
    nonisolated func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update {
                        // Unfinished transactions are redelivered forever.
                        await transaction.finish()
                    }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Presentation order on the paywall: cheapest commitment first.
    private func orderIndex(_ kind: PurchaseProductKind) -> Int {
        switch kind {
        case .monthly: 0
        case .yearly: 1
        }
    }
}
