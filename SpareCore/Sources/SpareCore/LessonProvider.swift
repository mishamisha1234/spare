import Foundation

/// Events emitted while a lesson is generated.
///
/// Draft events are internal pipeline signals — they feed pass 2 and drive
/// progress indicators. Only `revisedDelta` text is ever shown to the reader.
/// See `RevisionGate` for the ordering rules.
public enum LessonStreamEvent: Sendable, Equatable {
    case metadata(LessonMetadata)
    /// Draft (pass 1) text for a chapter. Not reader-facing.
    case draftDelta(chapter: Int, text: String)
    case draftChapterFinished(chapter: Int)
    /// Revised (pass 2) text for a chapter. Reader-facing, append-only.
    case revisedDelta(chapter: Int, text: String)
    case revisedChapterFinished(chapter: Int)
    /// Canonical fully revised lesson; the value persisted as `bodyMarkdown`.
    case finished(Lesson)
}

public enum LessonProviderError: Error, Equatable, Sendable {
    case missingAPIKey
    case network(String)
    case httpStatus(code: Int, message: String)
    case decoding(String)
    case refused(category: String?, explanation: String?)
    case cancelled
    case malformedStream(String)

    public var isRetryable: Bool {
        switch self {
        case .network, .malformedStream: return true
        case .httpStatus(let code, _): return code == 429 || code >= 500
        case .missingAPIKey, .decoding, .refused, .cancelled: return false
        }
    }
}

/// Every network call in the app goes through this protocol.
///
/// v1 ships `AnthropicDirectProvider` (device → Anthropic API) and
/// `MockProvider` (tests, previews, offline). Moving to a server proxy later
/// must be a single new conformance plus one line changed at the injection site.
public protocol LessonProvider: Sendable {
    /// 5 suggestions for the window: at least 3 domains, exactly 1 wildcard,
    /// nothing semantically close to the last 30 completed lessons.
    func suggestTopics(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) async throws -> [TopicSuggestion]

    /// Both passes, no streaming. Used where progressive text isn't needed.
    func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson

    /// Streaming generation. Draft and revision events interleave per chapter;
    /// feed the stream into a `RevisionGate` rather than rendering directly.
    func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) -> AsyncThrowingStream<LessonStreamEvent, Error>

    func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion

    func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson
}
