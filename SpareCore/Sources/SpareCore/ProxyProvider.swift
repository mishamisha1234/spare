import Foundation

/// Calls the Spare proxy, which holds the API key and enforces the tiers.
///
/// The shipping path. Three things move off the device by using it:
///
/// - **The key.** It lives in a Cloudflare secret binding. There is nothing on
///   the device to extract, and no per-user key to revoke.
/// - **The limits.** Free-tier counting used to be local, which the Phase 5
///   note recorded as spoofable and accepted. The proxy now decides, so editing
///   a local value changes nothing that costs money.
/// - **The subscription check.** `EntitlementService` still gates the UI, but
///   the server independently asks Apple before serving premium content, so a
///   patched client gets a refusal rather than a lesson.
///
/// Nothing about how a lesson is written lives here either. This is
/// `GenerationPipeline` with a `ProxyRoute`, so the prompts, the two passes, the
/// retry behaviour, and the streaming contract are byte-identical to the direct
/// path. That equivalence is the point: a bug that only appears in production
/// would be a bug in a pipeline CI never runs.
public struct ProxyProvider: LessonProvider {

    public typealias Configuration = GenerationPipeline.Configuration

    private let pipeline: GenerationPipeline

    /// - Parameters:
    ///   - baseURL: The proxy origin.
    ///   - deviceID: A stable per-install identifier. Spoofable, and meant to
    ///     be understood that way: with no accounts it raises abuse from
    ///     "edit a local flag" to "reinstall and lose your library", and no
    ///     further. The server's global spend ceiling is the real protection.
    ///   - receipt: The current subscription's JWS, read fresh on each call.
    ///     Evaluated per request rather than captured, so a purchase or an
    ///     expiry takes effect without a relaunch. Returns nil on the free
    ///     tier, and the proxy then serves free-tier content.
    ///   - operatorToken: The proxy's `ADMIN_TOKEN`, for the offline batch tool
    ///     only. The app never passes one. See `ProxyRoute`.
    public init(
        transport: any HTTPTransport,
        baseURL: URL,
        deviceID: String,
        receipt: @escaping @Sendable () async -> String? = { nil },
        ledger: any UsageLedger = NoopUsageLedger(),
        sleeper: any Sleeper = TaskSleeper(),
        configuration: Configuration = .standard,
        operatorToken: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        pipeline = GenerationPipeline(
            transport: transport,
            route: ProxyRoute(
                baseURL: baseURL,
                deviceID: deviceID,
                receipt: receipt,
                operatorToken: operatorToken
            ),
            ledger: ledger,
            sleeper: sleeper,
            configuration: configuration,
            now: now
        )
    }

    public func suggestTopics(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) async throws -> [TopicSuggestion] {
        try await pipeline.suggestTopics(window: window, profile: profile, history: history)
    }

    public func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        try await pipeline.generateLesson(topic: topic, window: window, profile: profile)
    }

    public func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand
    ) -> AsyncThrowingStream<LessonStreamEvent, Error> {
        pipeline.streamLesson(topic: topic, window: window, profile: profile, demand: demand)
    }

    public func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion {
        try await pipeline.generateRecallQuestion(for: lesson)
    }

    public func generatePostLessonTest(for lesson: Lesson) async throws -> [RecallQuestion] {
        try await pipeline.generatePostLessonTest(for: lesson)
    }

    public func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        try await pipeline.goDeeper(
            from: lesson, angle: angle, window: window, profile: profile
        )
    }
}
