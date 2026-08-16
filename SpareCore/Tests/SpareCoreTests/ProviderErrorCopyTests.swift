import XCTest
@testable import SpareCore

final class ProviderErrorCopyTests: XCTestCase {

    private func copy(_ error: LessonProviderError) -> ErrorPresentation {
        ProviderErrorCopy.presentation(for: error)
    }

    // MARK: - Every case is covered and says something

    func testEveryErrorProducesNonEmptyCopy() {
        let errors: [LessonProviderError] = [
            .missingAPIKey,
            .network("dropped"),
            .httpStatus(code: 429, message: ""),
            .httpStatus(code: 401, message: ""),
            .httpStatus(code: 503, message: ""),
            .httpStatus(code: 418, message: ""),
            .decoding("bad"),
            .malformedStream("truncated"),
            .refused(category: nil, explanation: nil),
            .cancelled,
        ]
        for error in errors {
            let presentation = copy(error)
            XCTAssertFalse(presentation.title.isEmpty, "\(error) has no title")
            XCTAssertFalse(presentation.message.isEmpty, "\(error) has no message")
        }
    }

    /// The distinction that motivated centralising this: being offline and
    /// being throttled resolve differently — one by reconnecting, one by
    /// waiting — so they must not read the same.
    func testOfflineAndRateLimitedAreDistinguishable() {
        let offline = copy(.network("dropped"))
        let throttled = copy(.httpStatus(code: 429, message: ""))
        XCTAssertNotEqual(offline.title, throttled.title)
        XCTAssertNotEqual(offline.message, throttled.message)
        XCTAssertTrue(throttled.message.lowercased().contains("wait"))
        XCTAssertTrue(offline.message.lowercased().contains("connection"))
    }

    // MARK: - Retryability matches reality

    /// A Retry button that cannot help is worse than none: it implies the
    /// failure is the reader's to fix by trying harder.
    func testOnlyGenuinelyRetryableFailuresOfferRetry() {
        XCTAssertTrue(copy(.network("x")).isRetryable)
        XCTAssertTrue(copy(.httpStatus(code: 429, message: "")).isRetryable)
        XCTAssertTrue(copy(.httpStatus(code: 500, message: "")).isRetryable)
        XCTAssertTrue(copy(.malformedStream("x")).isRetryable)

        XCTAssertFalse(copy(.missingAPIKey).isRetryable, "no key means retrying changes nothing")
        XCTAssertFalse(copy(.httpStatus(code: 401, message: "")).isRetryable, "a rejected key stays rejected")
        XCTAssertFalse(copy(.refused(category: nil, explanation: nil)).isRetryable, "a refusal is a decision")
    }

    /// The copy's retryability should agree with the provider's own retry
    /// logic wherever the provider has an opinion — otherwise the app tells
    /// the reader something different from what it does internally.
    func testCopyAgreesWithTheProviderOnTheClearCases() {
        let cases: [LessonProviderError] = [
            .network("x"),
            .httpStatus(code: 429, message: ""),
            .httpStatus(code: 503, message: ""),
            .malformedStream("x"),
            .missingAPIKey,
            .refused(category: nil, explanation: nil),
        ]
        for error in cases {
            XCTAssertEqual(
                copy(error).isRetryable, error.isRetryable,
                "\(error): the message and the retry policy disagree"
            )
        }
    }

    // MARK: - Routing to the fix

    func testKeyProblemsPointAtSettingsWhereTheFixActuallyIs() {
        XCTAssertTrue(copy(.missingAPIKey).pointsToSettings)
        XCTAssertTrue(copy(.httpStatus(code: 401, message: "")).pointsToSettings)
        XCTAssertTrue(copy(.httpStatus(code: 403, message: "")).pointsToSettings)
    }

    func testTransientFailuresDoNotSendPeopleToSettingsForNoReason() {
        XCTAssertFalse(copy(.network("x")).pointsToSettings)
        XCTAssertFalse(copy(.httpStatus(code: 429, message: "")).pointsToSettings)
        XCTAssertFalse(copy(.malformedStream("x")).pointsToSettings)
    }

    // MARK: - Tone

    /// The brief's rule: honest copy, no mascots. Also no apologising and no
    /// exclamation marks — this app doesn't perform contrition.
    func testCopyNeverApologisesOrShouts() {
        let all: [LessonProviderError] = [
            .missingAPIKey, .network("x"), .httpStatus(code: 429, message: ""),
            .httpStatus(code: 401, message: ""), .httpStatus(code: 500, message: ""),
            .decoding("x"), .refused(category: nil, explanation: nil), .cancelled,
        ]
        for error in all + [] {
            let presentation = copy(error)
            let text = (presentation.title + " " + presentation.message).lowercased()
            for banned in ["sorry", "oops", "whoops", "uh oh", "!"] {
                XCTAssertFalse(text.contains(banned), "\(error) copy contains \"\(banned)\"")
            }
        }
        let fallback = ProviderErrorCopy.unexpected
        XCTAssertFalse((fallback.title + fallback.message).contains("!"))
    }
}
