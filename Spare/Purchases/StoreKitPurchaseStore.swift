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

        return products
            .compactMap { product -> PurchaseProduct? in
                // An identifier the catalog doesn't recognise would grant an
                // unknown entitlement; drop it rather than guess.
                guard let kind = ProductCatalog.kind(forProductID: product.id) else { return nil }
                return PurchaseProduct(
                    id: product.id,
                    kind: kind,
                    displayName: product.displayName,
                    // StoreKit's own localized string — never assembled from
                    // `price` by hand, which would get currency and locale
                    // wrong in most of the world.
                    displayPrice: product.displayPrice,
                    price: product.price
                )
            }
            .sorted { orderIndex($0.kind) < orderIndex($1.kind) }
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
    /// Where several products are owned — a subscription plus lifetime — the
    /// first is enough. Every one of them entitles the same thing, and the
    /// server only needs one transaction to ask Apple about.
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
        case .lifetime: 2
        }
    }
}
