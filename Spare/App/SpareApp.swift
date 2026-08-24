import SwiftUI
import SwiftData
import SpareCore

/// `@MainActor` so `init` can touch UIKit's appearance proxies, which are
/// main-actor isolated. SwiftUI already runs an App's init and body on the
/// main actor, so this states what was true rather than changing behaviour.
@main
@MainActor
struct SpareApp: App {
    /// `-UITEST_RESET_STATE` (set by the screenshot UI test) forces an
    /// in-memory store and clears onboarding/appearance defaults, so every
    /// test run starts from the same clean slate regardless of what a
    /// previous run left on the simulator.
    private static var isUITestReset: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_STATE")
    }

    /// Seeds nothing, so the empty states are reachable for screenshots.
    private static var isUITestEmptyState: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITEST_EMPTY_STATE")
    }

    /// Every provider call fails, so the error states render their real copy
    /// rather than something written for the screenshot.
    private static var isUITestFailingProvider: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITEST_FAILING_PROVIDER")
    }

    private let container: ModelContainer
    private let provider: any LessonProvider
    private let pointsLedger: any PointsLedger
    private let entitlements: EntitlementService

    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = Theme.AppearanceMode.system.rawValue

    init() {
        NavigationBarChrome.flatten()

        let container = PersistenceStack.makeContainer(inMemory: Self.isUITestReset)
        self.container = container
        self.pointsLedger = PointsLedgerActor(modelContainer: container)

        // Rows written under a window this build no longer has. Reads nothing
        // in the common case; see `normalizeLegacyWindows`. Runs before
        // anything queries the store, because the suggestion cache filters on
        // `windowRaw` directly and a predicate cannot decode a legacy value.
        PersistenceStack.normalizeLegacyWindows(in: ModelContext(container))

        if Self.isUITestReset {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AppSettingsKey.hasCompletedOnboarding)
            defaults.removeObject(forKey: AppSettingsKey.appearanceMode)
            defaults.removeObject(forKey: AppSettingsKey.textSizeStep)
            defaults.removeObject(forKey: AppSettingsKey.recallNotificationTimeMinutes)
            defaults.removeObject(forKey: AppSettingsKey.wantsRecallReminders)
            defaults.removeObject(forKey: AppSettingsKey.hasRequestedNotificationPermission)
            if Self.isUITestEmptyState {
                // Straight past onboarding into an empty Home: the state a
                // fresh install actually reaches, and where the recall card
                // used to appear with a question for a lesson nobody read.
                defaults.set(true, forKey: AppSettingsKey.hasCompletedOnboarding)
            } else {
                Self.seedUITestState(container)
            }
        }

        // UI tests must never reach the network or spend anything, whatever
        // happens to be in this simulator's Keychain. The stub store also
        // means the paywall screenshots need no StoreKit configuration and
        // can never trigger a real purchase sheet.
        let purchases: any PurchaseStore = Self.isUITestReset
            ? StubPurchaseStore()
            : StoreKitPurchaseStore()
        self.entitlements = EntitlementService(store: purchases, container: container)

        if Self.isUITestFailingProvider {
            self.provider = FailingProvider()
        } else if Self.isUITestReset {
            self.provider = MockProvider()
        } else {
            self.provider = Self.makeLiveProvider(container: container, purchases: purchases)
        }
    }

    /// Builds the shipping provider.
    ///
    /// `ProxyProvider` is the path a released build takes: the Anthropic key
    /// lives in the proxy's secrets, and the tier limits are enforced there
    /// rather than on a device that can be edited.
    ///
    /// `AnthropicDirectProvider` survives only in debug builds, behind the same
    /// condition as the Settings key field, so generation can be worked on
    /// without deploying the proxy. Keeping both reachable from one build is
    /// what makes it possible to tell a proxy problem from a generation problem
    /// — the pipeline either side of the route is the same code.
    private static func makeLiveProvider(
        container: ModelContainer,
        purchases: any PurchaseStore
    ) -> any LessonProvider {
        let ledger = UsageLedgerActor(modelContainer: container)

        #if DEBUG
        let keyStore = KeychainAPIKeyStore()
        let direct = AnthropicDirectProvider(
            transport: FoundationHTTPTransport(),
            keyStore: keyStore,
            ledger: ledger
        )
        #endif

        guard let baseURL = ProxyConfiguration.baseURL() else {
            // No usable SPProxyBaseURL: a build configuration mistake. Falling
            // back to samples keeps the app usable and obviously wrong, which
            // is better than sending every request at a URL that cannot exist
            // and calling it a network error.
            #if DEBUG
            return KeyGatedProvider(
                keyed: direct, fallback: MockProvider(), keyStore: keyStore
            )
            #else
            return MockProvider()
            #endif
        }

        let proxy = ProxyProvider(
            transport: FoundationHTTPTransport(),
            baseURL: baseURL,
            deviceID: DeviceIdentity.current(),
            // Read per request, not captured: a purchase, a restore, or an
            // expiry has to take effect without a relaunch.
            receipt: { await purchases.currentReceipt() },
            ledger: ledger
        )

        #if DEBUG
        return KeyGatedProvider(keyed: direct, fallback: proxy, keyStore: keyStore)
        #else
        return proxy
        #endif
    }

    /// Seeds a completed lesson with an already-due recall item, so the
    /// screenshot walkthrough can reach the Home recall card without a
    /// multi-day simulated wait. Test-only: never runs without
    /// `-UITEST_RESET_STATE`.
    ///
    /// Deliberately seeds no entitlement, so the walkthrough starts on the
    /// free tier and photographs the locked states and the paywall before
    /// buying its way past them through `StubPurchaseStore`.
    private static func seedUITestState(_ container: ModelContainer) {
        let context = ModelContext(container)
        let lesson = StoredLesson(
            title: "Why bridges hum",
            subtitle: "A 3-minute one thing",
            topicTag: "Engineering",
            window: .three,
            bodyMarkdown: MockProvider.fixtureLesson(
                topic: TopicSuggestion(title: "Why bridges hum", hook: "", domainTag: "Engineering"),
                window: .three
            ).bodyMarkdown,
            surprisingClaim: "Pedestrians synchronising their steps fed the wobble that was correcting it.",
            deeperAngles: [
                "The broader physics of resonance in built structures",
                "How a tuned mass damper actually works",
                "The case against over-damping: when flexibility is safer",
            ],
            completedAt: .now,
            scrollProgress: 1
        )
        context.insert(lesson)
        context.insert(StoredRecallItem(
            lessonID: lesson.id,
            question: "What actually drove the Millennium Bridge's sway?",
            answer: "Pedestrians synchronising their steps with the deck",
            distractors: [
                "Wind alone",
                "A construction fault in the deck",
                "Traffic on a nearby road",
            ],
            explanation: "Each stride correction fed the wobble it was correcting.",
            dueAt: .distantPast
        ))
        // A part-read course, so the walkthrough can photograph the resume
        // state on the Home circle. Deliberately not visible at the start:
        // the walkthrough begins on the free tier, where the course window
        // is locked and resume is suppressed, so this only surfaces after
        // the purchase step — which is also the correct product behaviour.
        let course = StoredLesson(
            title: "How planes got safe",
            subtitle: "A 30-minute course",
            topicTag: "Engineering",
            window: .thirty,
            bodyMarkdown: MockProvider.fixtureChapterBodies(
                topic: TopicSuggestion(title: "How planes got safe", hook: "", domainTag: "Engineering"),
                window: .thirty
            ).joined(separator: "\n\n"),
            surprisingClaim: "Every rule in the manual was written after a crash.",
            deeperAngles: ["Context", "Mechanism", "Counterargument"],
            scrollProgress: 0.4
        )
        context.insert(course)

        try? context.save()
    }

    /// `-UITEST_COLOR_SCHEME` (light/dark) forces the appearance for
    /// screenshot determinism, overriding both the stored preference and the
    /// simulator's actual system setting.
    private var appearanceMode: Theme.AppearanceMode {
        if let forced = ProcessInfo.processInfo.environment["UITEST_COLOR_SCHEME"],
           let mode = Theme.AppearanceMode(rawValue: forced) {
            return mode
        }
        return Theme.AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .themedAppearance(appearanceMode)
                .environment(\.lessonProvider, provider)
                .environment(\.pointsLedger, pointsLedger)
                .entitlementService(entitlements)
        }
        .modelContainer(container)
    }
}
