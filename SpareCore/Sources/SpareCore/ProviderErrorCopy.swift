import Foundation

/// What to actually put on screen when generation fails.
public struct ErrorPresentation: Sendable, Equatable {
    /// A short statement of what happened. Never an apology, never a mascot.
    public var title: String
    /// One sentence: what went wrong, and what the reader can do about it.
    public var message: String
    /// Whether trying the same thing again could plausibly work. Drives
    /// whether a Retry button is offered at all — a button that cannot help
    /// is worse than no button, because it implies the failure is the
    /// reader's to fix.
    public var isRetryable: Bool
    /// True when the fix is in Settings, so the screen can offer that instead.
    public var pointsToSettings: Bool

    public init(title: String, message: String, isRetryable: Bool, pointsToSettings: Bool = false) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.pointsToSettings = pointsToSettings
    }
}

/// One place that turns a `LessonProviderError` into words.
///
/// Centralised so every screen says the same thing about the same failure.
/// Before this, three screens each had their own "Couldn't load…" string, and
/// a rate limit was indistinguishable from being offline — which matters,
/// because one resolves by waiting and the other by reconnecting.
public enum ProviderErrorCopy {

    public static func presentation(for error: LessonProviderError) -> ErrorPresentation {
        switch error {
        case .missingAPIKey:
            return ErrorPresentation(
                title: "No API key",
                message: "Add an Anthropic key in Settings to generate live lessons. Until then, Spare uses its built-in samples.",
                isRetryable: false,
                pointsToSettings: true
            )

        case .network:
            return ErrorPresentation(
                title: "No connection",
                message: "Spare couldn't reach Anthropic. Check your connection and try again.",
                isRetryable: true
            )

        case .httpStatus(let code, _) where code == 429:
            return ErrorPresentation(
                title: "Rate limited",
                message: "Anthropic is throttling requests right now. Waiting a minute usually clears it.",
                isRetryable: true
            )

        case .httpStatus(let code, _) where code == 401 || code == 403:
            return ErrorPresentation(
                title: "Key rejected",
                message: "Anthropic wouldn't accept that key. Check it in Settings — it may have been revoked.",
                isRetryable: false,
                pointsToSettings: true
            )

        case .httpStatus(let code, _) where code >= 500:
            return ErrorPresentation(
                title: "Anthropic is having trouble",
                message: "The API returned an error on their side. Trying again shortly usually works.",
                isRetryable: true
            )

        case .httpStatus:
            return ErrorPresentation(
                title: "Request refused",
                message: "Anthropic rejected the request. If it keeps happening, check your key in Settings.",
                isRetryable: false,
                pointsToSettings: true
            )

        case .refused:
            return ErrorPresentation(
                title: "The model declined",
                message: "It wouldn't write about this topic. Picking a different one is the fastest way past it.",
                isRetryable: false
            )

        case .decoding, .malformedStream:
            return ErrorPresentation(
                title: "Generation failed",
                message: "The lesson came back unreadable. Trying again usually works.",
                isRetryable: true
            )

        case .cancelled:
            return ErrorPresentation(
                title: "Stopped",
                message: "Generation stopped before it finished.",
                isRetryable: true
            )
        }
    }

    /// For a failure that isn't a `LessonProviderError` — an unexpected one.
    /// Deliberately vague about cause but honest that it's unexplained,
    /// rather than blaming the connection when that isn't known.
    public static let unexpected = ErrorPresentation(
        title: "Something went wrong",
        message: "That didn't finish, and Spare isn't sure why. Trying again is worth a go.",
        isRetryable: true
    )
}
