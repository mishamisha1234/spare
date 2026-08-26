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

    /// Starts on Home with the seed intact.
    ///
    /// `-UITEST_EMPTY_STATE` also skips onboarding, but it skips the seed with
    /// it. A pass that is about a screen *behind* onboarding and needs a
    /// populated library -- the trial's four -- otherwise pays four taps and
    /// four screens of flake surface per launch for something it is not
    /// testing. The main walkthrough still walks onboarding, because that is
    /// one of the things it is for.
    private static var isUITestSkipOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITEST_SKIP_ONBOARDING")
    }

    /// Every provider call fails, so the error states render their real copy
    /// rather than something written for the screenshot.
    private static var isUITestFailingProvider: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITEST_FAILING_PROVIDER")
    }

    /// Which point in a seven-day trial a UI test starts from, or nil for
    /// "no trial at all".
    ///
    /// Nil is the default and it matters. A test that does not name a trial
    /// state gets no trial store, so the offer, the nudge and the day-7
    /// summary are all inert -- otherwise every existing walkthrough would
    /// pick up a sheet it was not written for, and the free-tier screens the
    /// paywall exists to explain would stop being reachable the moment a
    /// trial started mid-run.
    ///
    /// The states themselves are the ones a human cannot otherwise see
    /// without waiting four days and then three more, which is exactly the
    /// kind of state that ships unlooked-at.
    private static var uiTestTrial: TrialMirror? {
        let arguments = ProcessInfo.processInfo.arguments
        let now = Date()
        if arguments.contains("-UITEST_TRIAL_ELIGIBLE") {
            return .eligible
        }
        if arguments.contains("-UITEST_TRIAL_DAY4") {
            // Four days in, six lessons read, three days left.
            return TrialMirror(
                status: .active,
                remainingLessons: 4,
                remainingCourses: 1,
                startedAt: now.addingTimeInterval(-4 * 86_400),
                expiresAt: now.addingTimeInterval(3 * 86_400)
            )
        }
        if arguments.contains("-UITEST_TRIAL_EXPIRED") {
            return TrialMirror(
                status: .ended,
                startedAt: now.addingTimeInterval(-8 * 86_400),
                expiresAt: now.addingTimeInterval(-86_400)
            )
        }
        return nil
    }

    private let container: ModelContainer
    private let provider: any LessonProvider
    /// Where a lesson's recall question and test come from. Real only on the
    /// proxy path: there is no shared pool to attach to anywhere else.
    private let attachments: any AttachmentStore
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
                if Self.isUITestSkipOnboarding {
                    defaults.set(true, forKey: AppSettingsKey.hasCompletedOnboarding)
                }
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
        self.entitlements = EntitlementService(
            store: purchases,
            trialStore: Self.makeTrialStore(purchases: purchases),
            container: container
        )

        if Self.isUITestFailingProvider {
            self.provider = FailingProvider()
            self.attachments = NoAttachmentStore()
        } else if Self.isUITestReset {
            self.provider = MockProvider()
            self.attachments = NoAttachmentStore()
        } else {
            self.provider = Self.makeLiveProvider(container: container, purchases: purchases)
            self.attachments = Self.makeAttachmentStore(purchases: purchases)
        }
    }

    /// Where the trial mirror comes from.
    ///
    /// A stub under UI tests, for the same reason `StubPurchaseStore` is:
    /// tests must never reach the network, and a walkthrough that had to wait
    /// out a real seven-day clock would photograph nothing. Nil when there is
    /// no proxy configured, which leaves the trial permanently `eligible` and
    /// therefore granting nothing.
    private static func makeTrialStore(purchases: any PurchaseStore) -> (any TrialStore)? {
        if Self.isUITestReset {
            // Nil unless the test named a state. See `uiTestTrial`.
            guard let mirror = Self.uiTestTrial else { return nil }
            return StubTrialStore(mirror)
        }
        guard let baseURL = ProxyConfiguration.baseURL() else { return nil }
        return ProxyTrialStore(
            transport: FoundationHTTPTransport(),
            baseURL: baseURL,
            deviceID: DeviceIdentity.current(),
            receipt: { await purchases.currentReceipt() }
        )
    }

    /// The proxy's attachment store, or one that attaches nothing.
    ///
    /// Nothing rather than a local substitute, deliberately. Attachments only
    /// mean anything where a pool is shared between readers; on the direct
    /// route and the mock there is exactly one reader, so generating per
    /// reader is not a cost cliff, it is the only thing that makes sense.
    private static func makeAttachmentStore(
        purchases: any PurchaseStore
    ) -> any AttachmentStore {
        guard let baseURL = ProxyConfiguration.baseURL() else { return NoAttachmentStore() }
        return ProxyAttachmentStore(
            transport: FoundationHTTPTransport(),
            baseURL: baseURL,
            deviceID: DeviceIdentity.current(),
            receipt: { await purchases.currentReceipt() }
        )
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
                .environment(\.attachmentStore, attachments)
                .environment(\.pointsLedger, pointsLedger)
                .entitlementService(entitlements)
        }
        .modelContainer(container)
    }
}
