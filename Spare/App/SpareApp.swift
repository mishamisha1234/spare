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

    private let container: ModelContainer
    private let provider: any LessonProvider
    private let pointsLedger: any PointsLedger

    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = Theme.AppearanceMode.system.rawValue

    init() {
        NavigationBarChrome.flatten()

        let container = PersistenceStack.makeContainer(inMemory: Self.isUITestReset)
        self.container = container
        self.pointsLedger = PointsLedgerActor(modelContainer: container)

        if Self.isUITestReset {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AppSettingsKey.hasCompletedOnboarding)
            defaults.removeObject(forKey: AppSettingsKey.appearanceMode)
            defaults.removeObject(forKey: AppSettingsKey.textSizeStep)
            defaults.removeObject(forKey: AppSettingsKey.recallNotificationTimeMinutes)
            Self.seedUITestState(container)
        }

        // UI tests must never reach the network or spend anything, whatever
        // happens to be in this simulator's Keychain.
        if Self.isUITestReset {
            self.provider = MockProvider()
        } else {
            let keyStore = KeychainAPIKeyStore()
            self.provider = KeyGatedProvider(
                live: AnthropicDirectProvider(
                    transport: FoundationHTTPTransport(),
                    keyStore: keyStore,
                    ledger: UsageLedgerActor(modelContainer: container)
                ),
                offline: MockProvider(),
                keyStore: keyStore
            )
        }
    }

    /// Seeds a completed lesson with an already-due recall item, and a
    /// premium entitlement, so the screenshot walkthrough can reach the Home
    /// recall card and the post-lesson test without a multi-day simulated
    /// wait or a purchase flow that doesn't exist yet (Phase 5). Test-only:
    /// this never runs without `-UITEST_RESET_STATE`.
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
        context.insert(StoredEntitlement(tier: .monthly))
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
        }
        .modelContainer(container)
    }
}
