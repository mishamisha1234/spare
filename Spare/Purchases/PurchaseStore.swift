import Foundation
import SpareCore

/// What came back from asking to buy something.
enum PurchaseOutcome: Sendable, Equatable {
    case purchased
    /// Ask to Buy, or a bank confirmation step. Not a failure — the
    /// transaction may still complete later, via the updates stream.
    case pending
    case cancelled
}

enum PurchaseStoreError: LocalizedError, Equatable {
    case productUnavailable
    case unverified

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "That option isn't available right now. Try again in a moment."
        case .unverified:
            "The App Store couldn't verify that purchase."
        }
    }
}

/// Everything the app needs from the store, behind one protocol.
///
/// Same reasoning as `LessonProvider`: the real implementation talks to
/// StoreKit, and a stub drives the paywall in UI tests and previews. CI can
/// then screenshot the paywall and the locked states without a StoreKit
/// configuration, a sandbox account, or any risk of a real purchase.
protocol PurchaseStore: Sendable {
    func loadProducts() async throws -> [PurchaseProduct]
    func purchase(_ kind: PurchaseProductKind) async throws -> PurchaseOutcome
    /// `AppStore.sync()` in the real implementation. Restores are for the
    /// user's benefit on a new device; entitlements themselves always come
    /// from `ownedProductIDs()`.
    func restore() async throws
    func ownedProductIDs() async -> Set<String>
    /// Fires whenever StoreKit reports a transaction change, so entitlements
    /// can be re-read. Covers renewals, refunds, and purchases that complete
    /// outside the app.
    func transactionUpdates() -> AsyncStream<Void>
    /// The signed transaction the proxy presents to Apple, or nil on the free
    /// tier.
    ///
    /// The device does not decide it is premium; it hands over a receipt and
    /// the server asks Apple. `ownedProductIDs` above is for the UI, which can
    /// afford to trust the local answer because being wrong there costs a
    /// misdrawn lock icon rather than a lesson.
    func currentReceipt() async -> String?
}

/// Deterministic stand-in for UI tests and previews.
///
/// Starts owning nothing, so the free-tier locked states are what a
/// walkthrough sees first; `purchase` grants the product immediately, so the
/// same walkthrough can then exercise the unlocked path.
actor StubPurchaseStore: PurchaseStore {
    private var owned: Set<String>
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    init(owned: Set<String> = []) {
        self.owned = owned
        var escaped: AsyncStream<Void>.Continuation!
        self.stream = AsyncStream { escaped = $0 }
        self.continuation = escaped
    }

    /// Prices chosen to exercise the real pricing arithmetic: 12 x 4.99 is
    /// 59.88, so the 39.99 yearly shows a genuine 33% saving rather than a
    /// hardcoded badge.
    func loadProducts() async throws -> [PurchaseProduct] {
        [
            PurchaseProduct(
                id: ProductCatalog.monthlyID, kind: .monthly,
                displayName: "Monthly", displayPrice: "$4.99", price: 4.99
            ),
            PurchaseProduct(
                id: ProductCatalog.yearlyID, kind: .yearly,
                displayName: "Yearly", displayPrice: "$39.99", price: 39.99
            ),
            PurchaseProduct(
                id: ProductCatalog.lifetimeID, kind: .lifetime,
                displayName: "Lifetime", displayPrice: "$99.99", price: 99.99
            ),
        ]
    }

    func purchase(_ kind: PurchaseProductKind) async throws -> PurchaseOutcome {
        owned.insert(ProductCatalog.productID(for: kind))
        continuation.yield(())
        return .purchased
    }

    func restore() async throws {
        continuation.yield(())
    }

    func ownedProductIDs() async -> Set<String> { owned }

    /// Always nil. There is no such thing as a fake receipt the proxy would
    /// accept, and a stub that returned one would be pretending the server
    /// check passes. UI tests reach the network through `MockProvider` anyway.
    func currentReceipt() async -> String? { nil }

    nonisolated func transactionUpdates() -> AsyncStream<Void> { stream }
}
