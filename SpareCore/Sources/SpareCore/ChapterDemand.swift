import Foundation

/// Back-pressure from the reader to the generator.
///
/// A 45-minute mini-course is 6 chapters and 12 API calls. A reader who stops
/// after chapter 2 must not be billed for chapters 3–6, so the generator does
/// not run ahead on its own: it blocks on this until the reader's position
/// says the next chapter is actually wanted.
///
/// `allowedThrough` is the source of truth; the stream is only a wake-up
/// signal, so a `readerReached` that lands before anyone is waiting is never
/// missed.
public final class ChapterDemand: @unchecked Sendable {

    private let lock = NSLock()
    private var allowedThrough: Int
    private let continuation: AsyncStream<Int>.Continuation
    private let updates: AsyncStream<Int>

    /// - Parameter prefetch: how many chapters past the reader's own chapter
    ///   may be generated. 1 means "draft and revise chapter N+1 while the
    ///   reader is in chapter N", which is the rule the Reader is built on.
    public let prefetch: Int

    public init(prefetch: Int = 1) {
        self.prefetch = prefetch
        self.allowedThrough = prefetch
        var escapee: AsyncStream<Int>.Continuation!
        self.updates = AsyncStream<Int> { escapee = $0 }
        self.continuation = escapee
    }

    /// Highest chapter index the generator is currently cleared to produce.
    public var currentAllowance: Int {
        lock.lock()
        defer { lock.unlock() }
        return allowedThrough
    }

    /// The reader is now in `chapter`. Clears generation up to
    /// `chapter + prefetch`.
    public func readerReached(chapter: Int) {
        raise(to: chapter + prefetch)
    }

    /// Removes back-pressure entirely. Used by non-chaptered formats and by
    /// callers that genuinely want the whole thing up front.
    public func allowAll() {
        raise(to: .max)
    }

    /// No more chapters will ever be requested; unblocks any waiter so the
    /// generator can shut down instead of hanging.
    public func finish() {
        continuation.finish()
    }

    private func raise(to value: Int) {
        lock.lock()
        let changed = value > allowedThrough
        if changed { allowedThrough = value }
        lock.unlock()
        if changed { continuation.yield(value) }
    }

    /// Suspends until `chapter` is cleared for generation.
    ///
    /// Throws `.cancelled` if the surrounding task is cancelled or the demand
    /// is finished without ever reaching that chapter — both mean "the reader
    /// left", and neither should produce another API call.
    public func waitUntilAllowed(chapter: Int) async throws {
        if currentAllowance >= chapter { return }

        for await value in updates {
            if value >= chapter { return }
            try Task.checkCancellation()
        }

        try Task.checkCancellation()
        throw LessonProviderError.cancelled
    }

    /// Convenience for callers that want everything immediately.
    public static func eager() -> ChapterDemand {
        let demand = ChapterDemand()
        demand.allowAll()
        return demand
    }
}
