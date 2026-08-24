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
    /// Withdraws every `revisedDelta` already sent for this chapter: the pass
    /// that produced them is being run again.
    ///
    /// The one exception to append-only, and it exists for one reason. A
    /// lesson's length is a promise about the reader's time, and a revision
    /// that lands materially under the floor has broken it — 1,555 words
    /// against a 2,400-word floor is eight minutes of reading sold as fifteen.
    /// That can only be known when the pass finishes, by which point its text
    /// is already on the screen, so the only honest options are to show it
    /// anyway or to take it back. This is taking it back.
    ///
    /// Rare by construction: it fires on a failed length check, not on a
    /// network error, and the retry that follows it is bounded. A consumer that
    /// ignores it will show a lesson twice over — `RevisionGate` handles it, and
    /// nothing should be reading these events without one.
    case revisionRestarted(chapter: Int)
    /// Canonical fully revised lesson; the value persisted as `bodyMarkdown`.
    case finished(Lesson)
}

/// A refusal the Spare proxy issued, as opposed to one Anthropic issued.
///
/// Distinguished because the next step differs entirely. An HTTP failure is
/// something to retry or a key to fix; these are a tier boundary to cross or a
/// wait to sit out, and telling a reader who has used today's free lesson to
/// "check your key in Settings" would be both wrong and, on a ship build,
/// pointing at a screen that doesn't exist.
///
/// The app's own `EntitlementService` should normally have caught these before a
/// request was made. Reaching one means the two disagreed — a clock skew, a
/// lapsed subscription the device hasn't noticed, a tampered build — and the
/// server is the side that is right.
public enum ProxyLimit: String, Sendable, Equatable, CaseIterable {
    /// The free tier's one lesson a day is spent.
    case dailyLesson = "dailyLimitReached"
    /// This length is premium-only.
    case lockedWindow
    /// Premium's monthly mini-course allowance is spent.
    case courseCap = "courseCapReached"
    /// Going deeper is premium-only.
    case premiumOnly = "goDeeperLocked"
    /// Spare's own monthly spend ceiling was reached; free generation is paused.
    case spendCeiling = "spendCeilingReached"
    /// The proxy couldn't reach Apple to confirm the subscription. Fails closed
    /// to free rather than open to premium, and is worth retrying.
    case verificationUnavailable

    /// Unrecognised codes map to nil rather than to a catch-all case, so a new
    /// server code surfaces as a plain HTTP status instead of borrowing copy
    /// written for a different situation.
    public init?(code: String) {
        guard let limit = ProxyLimit(rawValue: code) else { return nil }
        self = limit
    }
}

public enum LessonProviderError: Error, Equatable, Sendable {
    case missingAPIKey
    case network(String)
    case httpStatus(code: Int, message: String)
    case decoding(String)
    case refused(category: String?, explanation: String?)
    case cancelled
    case malformedStream(String)
    /// Generation kept coming back materially shorter than the length the
    /// reader chose, and the retries are spent.
    ///
    /// Surfaced rather than served. The alternative — hand over a lesson that
    /// is two-thirds the length it was sold as — is the failure this whole
    /// check exists to stop, and it is worse for being invisible: nobody
    /// reports a lesson that was merely short.
    case underWordFloor(words: Int, floor: Int)
    /// A tier or spend limit the proxy enforced. `message` is the server's own
    /// wording, which is written for the reader.
    case limited(ProxyLimit, message: String)

    public var isRetryable: Bool {
        switch self {
        case .network, .malformedStream: return true
        // 502 is the proxy's word for "Anthropic refused what we sent", as
        // distinct from 503, "Anthropic is down". The first is a bug or an
        // account problem at this end and does not improve on the third
        // attempt; the second usually does. They used to be the same status and
        // therefore the same three wasted retries.
        case .httpStatus(let code, _): return code == 429 || (code >= 500 && code != 502)
        case .missingAPIKey, .decoding, .refused, .cancelled: return false
        // The pipeline has already retried this as many times as it is going
        // to. Offering the reader a button that runs the same two calls again
        // spends real money to reach the same answer.
        case .underWordFloor: return false
        // A ceiling clears and an Apple outage ends; a tier boundary doesn't
        // move by retrying, and offering a button that cannot help implies the
        // failure is the reader's to fix.
        case .limited(let limit, _):
            switch limit {
            case .spendCeiling, .verificationUnavailable: return true
            case .dailyLesson, .lockedWindow, .courseCap, .premiumOnly: return false
            }
        }
    }
}

/// Every network call in the app goes through this protocol.
///
/// Conformances: `ProxyProvider` (device → Spare proxy → Anthropic) is what
/// ships; `AnthropicDirectProvider` (device → Anthropic, with the user's own
/// key) is debug-only; `MockProvider` covers tests, previews, and offline.
///
/// The first two are the same `GenerationPipeline` with a different
/// `ProviderRoute`, which is what the note here used to predict would be
/// possible — it turned out to need a route abstraction rather than a second
/// conformance, because duplicating the pipeline would have left the shipping
/// copy as the one CI never runs.
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
    ///
    /// `demand` is the reader's back-pressure on chaptered formats: the
    /// generator waits on it before each chapter, so a reader who stops early
    /// is never billed for chapters they didn't reach. Non-chaptered formats
    /// ignore it.
    func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand
    ) -> AsyncThrowingStream<LessonStreamEvent, Error>

    func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion

    /// The immediate, optional test offered right after a lesson (premium).
    ///
    /// A separate call from `generateRecallQuestion`: that one question is
    /// scheduled for tomorrow and stored for offline use; this one is answered
    /// on the spot and never persisted as a schedule.
    ///
    /// Takes the window because the question count is a function of the
    /// length — two for a minute, ten for a course — and a finished `Lesson`
    /// does not record the length it was written for. Deriving it from the
    /// word count would be a guess, and the server validates the uploaded test
    /// against the exact number.
    ///
    /// Called once per *lesson*, by whichever device generated it, and the
    /// result is attached to the cache entry. Never called per reader: a
    /// 30-minute course read by two hundred premium users would otherwise be
    /// forty dollars of tests on a lesson that cost a dollar forty.
    func generatePostLessonTest(
        for lesson: Lesson,
        window: TimeWindow
    ) async throws -> [RecallQuestion]

    func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson
}

extension LessonProvider {
    /// Generates everything up front, with no reader back-pressure.
    ///
    /// Fine for single-unit formats and for tests. For a 30-minute
    /// mini-course this means paying for all four chapters whether or not
    /// they're read — the Reader always passes a real `ChapterDemand`.
    public func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) -> AsyncThrowingStream<LessonStreamEvent, Error> {
        streamLesson(topic: topic, window: window, profile: profile, demand: .eager())
    }
}
