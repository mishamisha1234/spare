import Foundation

/// Routes to `keyed` when an API key is stored, and to `fallback` when one
/// isn't. Re-evaluated per call, so a key can be added or cleared without
/// restarting.
///
/// Dev builds only, and only meaningful there. It exists so a developer with a
/// key in Settings can point generation straight at Anthropic on their own
/// account, while the same build with no key behaves like a shipped one. In
/// Phase 3 the fallback was `MockProvider`, which is what kept "runs end to end
/// with no network and no API key" true; now that the proxy exists, the shipping
/// path is `ProxyProvider` and the fallback is only `MockProvider` when there is
/// no proxy configured to fall back to.
///
/// The parameters are named for the condition rather than for what used to sit
/// behind it: `offline` stopped being accurate the moment the no-key path
/// started making real network calls.
public struct KeyGatedProvider: LessonProvider {

    private let keyed: any LessonProvider
    private let fallback: any LessonProvider
    private let keyStore: any APIKeyStore

    public init(
        keyed: any LessonProvider,
        fallback: any LessonProvider,
        keyStore: any APIKeyStore
    ) {
        self.keyed = keyed
        self.fallback = fallback
        self.keyStore = keyStore
    }

    private func active() async -> any LessonProvider {
        await keyStore.hasKey() ? keyed : fallback
    }

    public func suggestTopics(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) async throws -> [TopicSuggestion] {
        try await active().suggestTopics(window: window, profile: profile, history: history)
    }

    public func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        try await active().generateLesson(topic: topic, window: window, profile: profile)
    }

    public func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand
    ) -> AsyncThrowingStream<LessonStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let provider = await active()
                do {
                    for try await event in provider.streamLesson(
                        topic: topic, window: window, profile: profile, demand: demand
                    ) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion {
        try await active().generateRecallQuestion(for: lesson)
    }

    public func generatePostLessonTest(
        for lesson: Lesson,
        window: TimeWindow
    ) async throws -> [RecallQuestion] {
        try await active().generatePostLessonTest(for: lesson, window: window)
    }

    public func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        try await active().goDeeper(
            from: lesson, angle: angle, window: window, profile: profile
        )
    }
}
