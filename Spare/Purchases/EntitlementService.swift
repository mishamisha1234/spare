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
    /// Nil when there is no proxy to ask -- a build with no configured base
    /// URL, or previews. The trial then stays whatever the cache says, which
    /// for a fresh install is `eligible` and grants nothing.
    private let trialStore: (any TrialStore)?
    /// Where funnel events go after they are written down locally. See
    /// `FunnelEvent` for why only two of the six leave the device.
    private let funnel: any FunnelReporter
    private let context: ModelContext
    private var updatesTask: Task<Void, Never>?

    init(
        store: any PurchaseStore,
        trialStore: (any TrialStore)? = nil,
        funnel: any FunnelReporter = NoopFunnelReporter(),
        container: ModelContainer
    ) {
        self.store = store
        self.trialStore = trialStore
        self.funnel = funnel
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
        Task { await refreshTrial() }
    }

    // MARK: - Trial
    //
    // Everything here is a mirror. The server holds the trial next to this
    // device's metering and re-checks it atomically before generating, so the
    // worst a wrong answer here can do is draw a circle that then refuses.

    /// Claims this device's one trial, then mirrors whatever came back.
    ///
    /// Returns the result so the caller can distinguish "here is your week"
    /// from "you have already had one" -- the second must not be presented as
    /// a grant, and there is no second trial to fall back on.
    @discardableResult
    func startTrial() async -> TrialStartResult {
        guard let trialStore else {
            return TrialStartResult(started: false, reason: "unavailable", trial: snapshot.trial)
        }
        let result = await trialStore.start()
        apply(trial: result.trial)
        return result
    }

    /// Re-reads the mirror. Cheap, and called after anything that spends a
    /// trial lesson so the remaining count on screen is not a lesson behind.
    func refreshTrial() async {
        guard let trialStore else { return }
        apply(trial: await trialStore.status())
    }

    // MARK: - Instrumentation

    /// Writes one funnel event down, and forwards it if the server needs it.
    ///
    /// Fire and forget in both directions. This is a wiring check and a
    /// marketing number; neither is worth an error path in front of a reader,
    /// and neither is worth blocking anything on.
    func record(_ event: FunnelEvent) {
        context.insert(StoredFunnelEvent(kind: event))
        try? context.save()
        guard event.isReportedToServer else { return }
        Task { await funnel.report(event) }
    }

    /// This device's own funnel, for the DEBUG screen. One device cannot
    /// compute a percentage; see `FunnelEvent`.
    func funnelCounts() -> FunnelCounts {
        let stored = (try? context.fetch(FetchDescriptor<StoredFunnelEvent>())) ?? []
        return FunnelCounts.summarise(stored.compactMap(\.kind))
    }

    /// Whether this device may still be offered a free week.
    var isTrialEligible: Bool { snapshot.trial.status == .eligible }

    var isTrialing: Bool { snapshot.tier == .trialing }

    /// The trial has been had and is over. What the day-7 summary waits for.
    var hasTrialEnded: Bool { snapshot.trial.status == .ended }

    var trialLessonsRemaining: Int { snapshot.trial.remainingLessons }

    func trialDaysRemaining(now: Date = .now) -> Int {
        snapshot.trial.daysRemaining(now: now)
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
        apply(purchased: ProductCatalog.resolvedTier(forOwnedProductIDs: owned))
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
                // Recorded here rather than at a call site, so a purchase made
                // from any of the three sheets counts exactly once.
                record(.converted)
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
        // The trial's counters live on the server, so the only way to know
        // what a lesson cost is to ask. Done here rather than on a timer
        // because this is the moment the number on screen goes stale.
        if isTrialing { Task { await refreshTrial() } }
    }

    // MARK: - Persistence

    private func loadCachedSnapshot() {
        let stored = (try? context.fetch(FetchDescriptor<StoredEntitlement>()))?.first
        snapshot = stored?.snapshot ?? .free
        // A cached `.trialing` came from a purchase-free state, so seeding
        // `purchasedTier` from it would invent a subscription. Only a paying
        // cached tier is a claim about a purchase.
        purchasedTier = snapshot.tier.isPaying ? snapshot.tier : .free
    }

    /// The tier a purchase implies, which is not always the tier in force.
    ///
    /// Kept separate from `apply(trial:)` because the two arrive from
    /// different places at different times -- StoreKit and the proxy -- and
    /// whichever lands second must not erase the other. `resolvedTier` below
    /// is the single place they are combined.
    private var purchasedTier: Tier = .free

    private func apply(purchased tier: Tier) {
        purchasedTier = tier
        var updated = snapshot
        updated.tier = resolvedTier(purchased: tier, trial: snapshot.trial)
        apply(snapshot: updated)
    }

    private func apply(trial: TrialMirror) {
        var updated = snapshot
        updated.trial = trial
        updated.tier = resolvedTier(purchased: purchasedTier, trial: trial)
        apply(snapshot: updated)
    }

    /// A purchase always wins.
    ///
    /// Somebody who subscribes during their free week is a subscriber, and
    /// leaving them on `.trialing` would apply the trial's ten-lesson cap to
    /// a paid account. The server refuses to start a trial for a subscriber
    /// for the same reason from the other direction.
    private func resolvedTier(purchased: Tier, trial: TrialMirror) -> Tier {
        if purchased.isPaying { return purchased }
        return trial.isActive ? .trialing : .free
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
                lastFreeLessonDate: newValue.lastFreeLessonDate,
                trial: newValue.trial
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
