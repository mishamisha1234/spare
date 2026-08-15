import Foundation

/// Routes to the live provider when an API key is stored, and to the offline
/// provider when one isn't.
///
/// This is what keeps "runs end to end with no network and no API key" true
/// after Phase 3: a reader who has never opened Settings gets `MockProvider`
/// and a working app, not an error screen. It also means the key can be added
/// or cleared at any time without restarting.
public struct KeyGatedProvider: LessonProvider {

    private let live: any LessonProvider
    private let offline: any LessonProvider
    private let keyStore: any APIKeyStore

    public init(
        live: any LessonProvider,
        offline: any LessonProvider,
        keyStore: any APIKeyStore
    ) {
        self.live = live
        self.offline = offline
        self.keyStore = keyStore
    }

    private func active() async -> any LessonProvider {
        await keyStore.hasKey() ? live : offline
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

    public func generatePostLessonTest(for lesson: Lesson) async throws -> [RecallQuestion] {
        try await active().generatePostLessonTest(for: lesson)
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

extension AnthropicDirectProvider {
    /// Non-streaming whole-lesson generation, both passes. The Reader always
    /// streams; this exists for callers that want a finished lesson in hand.
    public func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        var result: Lesson?
        for try await event in streamLesson(
            topic: topic, window: window, profile: profile, demand: .eager()
        ) {
            if case .finished(let lesson) = event { result = lesson }
        }
        guard let result else {
            throw LessonProviderError.malformedStream("lesson stream finished without a result")
        }
        return result
    }
}
