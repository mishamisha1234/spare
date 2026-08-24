import Foundation

/// A provider whose every call fails with a given error.
///
/// Exists so the error states can be photographed in CI without contriving
/// them: the screens render the same `ProviderErrorCopy` output a real
/// network failure would produce, rather than a string invented for the
/// screenshot. Also useful for asserting that a failure on one screen
/// doesn't take another one down with it.
public struct FailingProvider: LessonProvider {
    public var error: LessonProviderError

    public init(error: LessonProviderError = .network("simulated failure")) {
        self.error = error
    }

    public func suggestTopics(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) async throws -> [TopicSuggestion] {
        throw error
    }

    public func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        throw error
    }

    public func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand
    ) -> AsyncThrowingStream<LessonStreamEvent, Error> {
        let error = self.error
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    public func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion {
        throw error
    }

    public func generatePostLessonTest(
        for lesson: Lesson,
        window: TimeWindow
    ) async throws -> [RecallQuestion] {
        throw error
    }

    public func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        throw error
    }
}
