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
    /// True when the limit is a tier boundary, so the screen can offer the
    /// paywall. Never both this and `pointsToSettings`: a screen offering two
    /// different fixes for one failure is a screen that has guessed.
    public var pointsToPaywall: Bool

    public init(
        title: String,
        message: String,
        isRetryable: Bool,
        pointsToSettings: Bool = false,
        pointsToPaywall: Bool = false
    ) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.pointsToSettings = pointsToSettings
        self.pointsToPaywall = pointsToPaywall
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

        // Deliberately does not name what it failed to reach. On a shipped build
        // that is the proxy, on a dev build with a key it is Anthropic, and this
        // type does not know which route the call took. "Anthropic" was accurate
        // in Phase 3 and became wrong the moment the key moved off the device —
        // a reader with no key has no idea what Anthropic is.
        case .network:
            return ErrorPresentation(
                title: "No connection",
                message: "Spare couldn't connect. Check your connection and try again.",
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

        // Split out from the 5xx block above: 502 from the Spare proxy means
        // Anthropic refused the request the proxy built, which is not Anthropic
        // having trouble and does not come right by waiting.
        case .httpStatus(let code, _) where code == 502:
            return ErrorPresentation(
                title: "Request refused",
                message: "Spare's request was rejected. That's a fault on Spare's side, not yours.",
                isRetryable: false
            )

        case .httpStatus(let code, _) where code >= 500:
            return ErrorPresentation(
                title: "Anthropic is having trouble",
                message: "The API returned an error on their side. Trying again shortly usually works.",
                isRetryable: true
            )

        // No longer points at Settings. The statuses that land here are now
        // mostly the proxy refusing a request it built wrong — a model it won't
        // pay for, a body over the size limit — which is a bug in Spare, not
        // something a reader can fix, and certainly not with a key a shipped
        // build has no field for. 401 and 403 are handled above and still do
        // point at Settings, because those genuinely are the key.
        case .httpStatus:
            return ErrorPresentation(
                title: "Request refused",
                message: "Spare's request was rejected. That's a fault on Spare's side, not yours.",
                isRetryable: false
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

        // The server's own wording is used for the message, because it is
        // written for the reader and stating the limit twice in two voices
        // would be worse than either. The title and the offered action are
        // decided here, where the rest of the app's copy lives.
        case .limited(let limit, let message):
            switch limit {
            case .dailyLesson:
                return ErrorPresentation(
                    title: "That's today's lesson",
                    message: message,
                    isRetryable: false,
                    pointsToPaywall: true
                )
            case .lockedWindow:
                return ErrorPresentation(
                    title: "Longer lessons are Premium",
                    message: message,
                    isRetryable: false,
                    pointsToPaywall: true
                )
            case .premiumOnly:
                return ErrorPresentation(
                    title: "Part of Premium",
                    message: message,
                    isRetryable: false,
                    pointsToPaywall: true
                )
            case .courseCap:
                // Already paying, so the paywall has nothing to offer. Waiting
                // for the month to turn is the only real answer, and saying so
                // is better than a button.
                return ErrorPresentation(
                    title: "Every course this month",
                    message: message,
                    isRetryable: false
                )
            case .spendCeiling:
                return ErrorPresentation(
                    title: "Spare is at its limit",
                    message: message,
                    isRetryable: true
                )
            case .verificationUnavailable:
                return ErrorPresentation(
                    title: "Couldn't check your subscription",
                    message: message,
                    isRetryable: true
                )
            }
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
