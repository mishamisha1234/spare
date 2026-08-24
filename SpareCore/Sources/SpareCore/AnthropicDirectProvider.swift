import Foundation

/// Calls the Anthropic Messages API directly from the device, with a key the
/// user supplies.
///
/// Dev builds only, behind the same build flag as the Settings key field. It
/// exists so generation can be worked on without deploying the proxy — the key
/// belongs to whoever is debugging, and the spend lands on their account.
///
/// Nothing about how a lesson is written lives here. That is
/// `GenerationPipeline`, which this type wraps with a `DirectRoute`; the two
/// providers differ only in where requests go.
public struct AnthropicDirectProvider: LessonProvider {

    public typealias Configuration = GenerationPipeline.Configuration

    private let pipeline: GenerationPipeline

    public init(
        transport: any HTTPTransport,
        keyStore: any APIKeyStore,
        ledger: any UsageLedger = NoopUsageLedger(),
        sleeper: any Sleeper = TaskSleeper(),
        configuration: Configuration = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        pipeline = GenerationPipeline(
            transport: transport,
            route: DirectRoute(keyStore: keyStore),
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

    public func generatePostLessonTest(
        for lesson: Lesson,
        window: TimeWindow
    ) async throws -> [RecallQuestion] {
        try await pipeline.generatePostLessonTest(for: lesson, window: window)
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
