import Foundation
import SwiftData
import SwiftUI
import SpareCore

/// The only place in the app that answers "is this allowed?".
///
/// Views never read a tier and never call `EntitlementRules` themselves.
/// They ask this service, get an `AccessDecision`, and render accordingly.
/// One consequence worth stating: because `AccessDecision.capped` carries no
/// paywall trigger, a view that routes "any denial" to the paywall cannot
/// accidentally show it to somebody who already pays.
///
/// The tier is cached in SwiftData so the app knows what someone owns before
/// StoreKit answers on a cold launch. `Transaction.currentEntitlements` is
/// the authority and overwrites the cache as soon as it responds.
@MainActor
final class EntitlementService: ObservableObject {

    @Published private(set) var snapshot: EntitlementSnapshot = .free
    @Published private(set) var products: [PurchaseProduct] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var errorMessage: String?
    /// Surfaced in Settings so the mini-course cap is visible before it bites.
    @Published private(set) var miniCoursesRemaining = EntitlementRules.premiumMiniCoursesPerMonth

    private let store: any PurchaseStore
    private let context: ModelContext
    private var updatesTask: Task<Void, Never>?

    init(store: any PurchaseStore, container: ModelContainer) {
        self.store = store
        self.context = ModelContext(container)
        loadCachedSnapshot()
        refreshMiniCourseUsage()
    }

    // No deinit cancelling `updatesTask`: deinit is nonisolated, so touching
    // main-actor state from it is a Swift 6 error (same trap as
    // ReaderViewModel). This service lives for the whole app session, so
    // there is nothing to tear down early anyway.

    // MARK: - Lifecycle

    /// Called once from the root view. Loads products, reconciles the cached
    /// tier against StoreKit, and starts listening for transaction changes.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            guard let updates = self?.store.transactionUpdates() else { return }
            for await _ in updates {
                await self?.refreshEntitlements()
            }
        }
        Task { await refreshEntitlements() }
        Task { await loadProducts() }
    }

    func loadProducts() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await store.loadProducts()
        } catch {
            // Not surfaced as an error banner: the paywall shows its own
            // "couldn't load" state, and a failed load on some other screen
            // isn't worth interrupting anyone over.
            products = []
        }
    }

    /// Re-reads what StoreKit says is owned and persists the result.
    func refreshEntitlements() async {
        let owned = await store.ownedProductIDs()
        apply(tier: ProductCatalog.resolvedTier(forOwnedProductIDs: owned))
    }

    // MARK: - Buying

    func purchase(_ kind: PurchaseProductKind) async -> PurchaseOutcome? {
        guard !isPurchasing else { return nil }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let outcome = try await store.purchase(kind)
            if outcome == .purchased {
                await refreshEntitlements()
            }
            return outcome
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "That purchase didn't go through."
            return nil
        }
    }

    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        defer { isRestoring = false }

        do {
            try await store.restore()
            await refreshEntitlements()
            // `isPaying`, not `hasPremiumAccess`: Restore is a question about
            // transactions. Somebody holding access with no receipt behind it
            // must still be told nothing was found, or they will believe a
            // purchase was restored that the App Store cannot produce.
            if !snapshot.tier.isPaying {
                errorMessage = "No previous purchase found on this Apple Account."
            }
        } catch {
            errorMessage = "Couldn't reach the App Store to restore."
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Gates
    //
    // Every one of these is a thin delegation to `EntitlementRules`. The
    // rules stay pure and testable on Linux; this type only supplies the
    // current snapshot, the clock, and the mini-course history.

    func canStartLesson(window: TimeWindow, now: Date = .now) -> AccessDecision {
        EntitlementRules.canStartLesson(
            snapshot,
            window: window,
            miniCourseStartDates: miniCourseStartDates(),
            now: now
        )
    }

    func canBrowseSuggestions(window: TimeWindow) -> AccessDecision {
        EntitlementRules.canBrowseSuggestions(snapshot, window: window)
    }

    func canGoDeeper() -> AccessDecision {
        EntitlementRules.canGoDeeper(snapshot)
    }

    func canTakePostLessonTest() -> AccessDecision {
        EntitlementRules.canTakePostLessonTest(snapshot)
    }

    var availableWindows: [TimeWindow] {
        EntitlementRules.availableWindows(snapshot)
    }

    /// Whether this *length* is behind Premium — a property of the plan, not
    /// of right now. Distinct from `canStartLesson`, which also fails on the
    /// free daily limit: a reader who has used today's lesson still owns the
    /// 3- and 7-minute lengths, so marking every circle locked would
    /// misdescribe what they bought.
    func isWindowLocked(_ window: TimeWindow) -> Bool {
        !availableWindows.contains(window)
    }

    /// Grants the premium experience. Drives affordances and copy.
    var hasPremiumAccess: Bool { snapshot.tier.hasPremiumAccess }

    /// There is a purchase behind the current tier. Drives anything that
    /// talks about, or is funded by, a transaction.
    var isPaying: Bool { snapshot.tier.isPaying }

    /// Records that a lesson actually started. Spends the free daily
    /// allowance and refreshes the mini-course count.
    func recordLessonStarted(window: TimeWindow, now: Date = .now) {
        apply(snapshot: EntitlementRules.consumingLesson(snapshot, now: now))
        refreshMiniCourseUsage()
    }

    // MARK: - Persistence

    private func loadCachedSnapshot() {
        let stored = (try? context.fetch(FetchDescriptor<StoredEntitlement>()))?.first
        snapshot = stored?.snapshot ?? .free
    }

    private func apply(tier: Tier) {
        var updated = snapshot
        updated.tier = tier
        apply(snapshot: updated)
    }

    private func apply(snapshot newValue: EntitlementSnapshot) {
        guard newValue != snapshot else { return }
        snapshot = newValue

        let stored = (try? context.fetch(FetchDescriptor<StoredEntitlement>()))?.first
        if let stored {
            stored.apply(newValue)
        } else {
            context.insert(StoredEntitlement(
                tier: newValue.tier,
                freeLessonsUsedToday: newValue.freeLessonsUsedToday,
                lastFreeLessonDate: newValue.lastFreeLessonDate
            ))
        }
        try? context.save()
    }

    /// Mini-course start dates come from the library itself rather than a
    /// counter, so the cap can't drift from what was actually generated.
    ///
    /// Filtered in Swift rather than in a `#Predicate`: the chaptered-window
    /// test lives on `TimeWindow.format`, which a SwiftData predicate can't
    /// see through, and a personal library is small enough that fetching it
    /// is cheaper than the indirection needed to push this into the store.
    private func miniCourseStartDates() -> [Date] {
        let lessons = (try? context.fetch(FetchDescriptor<StoredLesson>())) ?? []
        return lessons.filter(\.window.format.isChaptered).map(\.generatedAt)
    }

    private func refreshMiniCourseUsage() {
        miniCoursesRemaining = EntitlementRules.miniCoursesRemaining(
            startDates: miniCourseStartDates(),
            now: .now
        )
    }
}

// MARK: - Environment

/// Injected once at the root. `@EnvironmentObject` rather than a custom
/// `EnvironmentKey` because there is exactly one instance for the whole app
/// and views need to observe its changes.
extension View {
    func entitlementService(_ service: EntitlementService) -> some View {
        environmentObject(service)
    }
}
