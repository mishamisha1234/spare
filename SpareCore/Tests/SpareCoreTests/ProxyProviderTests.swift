import XCTest
@testable import SpareCore

/// What the app puts on the wire when it talks to the proxy, and how it reads
/// what comes back.
///
/// Same rule as everywhere else in this target: `FixtureTransport` only. No
/// network, no key, no spend. The server's own behaviour is tested in
/// `server/test`, against its own fixtures — these tests are about the contract
/// between the two, which is the part that can break silently because each side
/// looks fine alone.
final class ProxyProviderTests: XCTestCase {

    private let base = URL(string: "https://proxy.spare.test")!
    private let profile = ProfileSnapshot.empty
    private let topic = TopicSuggestion(
        title: "Why bridges hum", hook: "Wind makes steel sing.", domainTag: "Engineering"
    )

    private func makeProvider(
        _ transport: FixtureTransport,
        receipt: String? = nil,
        ledger: any UsageLedger = NoopUsageLedger()
    ) -> ProxyProvider {
        ProxyProvider(
            transport: transport,
            baseURL: base,
            deviceID: "device-fixture-0001",
            receipt: { receipt },
            ledger: ledger,
            sleeper: RecordingSleeper(),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }

    private func envelope(_ request: HTTPRequest) throws -> [String: JSONValue] {
        let body = try XCTUnwrap(request.body)
        let value = try JSONDecoder().decode(JSONValue.self, from: body)
        return try XCTUnwrap(value.objectValue)
    }

    private func collect(
        _ stream: AsyncThrowingStream<LessonStreamEvent, Error>
    ) async throws -> [LessonStreamEvent] {
        var events: [LessonStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    // MARK: - No key on the device

    func testNoAPIKeyIsEverSent() async throws {
        // The whole reason the proxy exists. There is no key store in this
        // provider's construction, so there is nothing to send even by mistake
        // — this pins that the request confirms it.
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.recallJSON)
        ))
        let provider = makeProvider(transport)

        _ = try await provider.generateRecallQuestion(for: fixtureLesson())

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertNil(request.headers["x-api-key"])
        XCTAssertNil(request.headers["anthropic-version"])
        let serialised = String(data: try XCTUnwrap(request.body), encoding: .utf8) ?? ""
        XCTAssertFalse(serialised.contains("sk-ant"))
    }

    func testSendsTheDeviceIdentifier() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
        ))
        let provider = makeProvider(transport)

        _ = try await provider.suggestTopics(window: .ten, profile: profile, history: [])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.headers["x-spare-device"], "device-fixture-0001")
    }

    // MARK: - Endpoints

    func testEachCallReachesItsOwnEndpoint() async throws {
        let suggestions = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
        ))
        _ = try await makeProvider(suggestions)
            .suggestTopics(window: .ten, profile: profile, history: [])
        XCTAssertEqual(suggestions.requests.first?.url.path, "/v1/suggestions")

        let recall = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.recallJSON)
        ))
        _ = try await makeProvider(recall).generateRecallQuestion(for: fixtureLesson())
        XCTAssertEqual(recall.requests.first?.url.path, "/v1/recall")

        let test = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.postLessonTestJSON)
        ))
        _ = try await makeProvider(test).generatePostLessonTest(for: fixtureLesson())
        XCTAssertEqual(test.requests.first?.url.path, "/v1/post-lesson-test")

        let deeper = FixtureTransport([
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.lessonJSON())),
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.lessonJSON())),
        ])
        _ = try await makeProvider(deeper).goDeeper(
            from: fixtureLesson(),
            angle: DeeperAngle(text: "How a tuned mass damper works"),
            window: .ten,
            profile: profile
        )
        XCTAssertEqual(deeper.requests.map(\.url.path), ["/v1/go-deeper", "/v1/go-deeper"])
    }

    func testBothLessonPassesShareOneEndpoint() async throws {
        // The meter counts endpoints. Two passes are one lesson to the reader,
        // so sending the revision somewhere else would charge a free user's
        // daily allowance twice for a single lesson.
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
        ])
        let provider = makeProvider(transport)

        _ = try await collect(provider.streamLesson(
            topic: topic, window: .ten, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requests.map(\.url.path), ["/v1/lesson", "/v1/lesson"])
    }

    func testChapterPassesUseTheChapterEndpoint() async throws {
        // The outline is part of starting the course, so it goes to /v1/lesson
        // and is what the course cap counts. The chapters that follow are not
        // separately chargeable.
        let outline = FixtureTransport.Step.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.outlineJSON())
        )
        var steps: [FixtureTransport.Step] = [outline]
        for _ in 0..<(TimeWindow.thirty.format.chapterCount * 2) {
            steps.append(.sse(HTTPFixtures.stream(json: HTTPFixtures.chapterJSON())))
        }
        let transport = FixtureTransport(steps)

        _ = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .thirty, profile: profile, demand: .eager()
        ))

        let paths = transport.requests.map(\.url.path)
        XCTAssertEqual(paths.first, "/v1/lesson")
        XCTAssertTrue(paths.dropFirst().allSatisfy { $0 == "/v1/chapter" })
    }

    // MARK: - The envelope

    func testEnvelopeCarriesTheMeteringFacts() async throws {
        // The server cannot enforce the free tier or key the cache without
        // these, and it must not have to read prompts to find them.
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
        ])
        let provider = makeProvider(transport)

        _ = try await collect(provider.streamLesson(
            topic: topic, window: .ten, profile: profile, demand: .eager()
        ))

        let sent = try envelope(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(sent["window"]?.stringValue, "ten")
        XCTAssertEqual(sent["format"]?.stringValue, "explainer")
        XCTAssertEqual(sent["topic"]?.stringValue, "Why bridges hum")
    }

    func testWindowAndFormatUseTheSameSpellingAsTheServer() async throws {
        // Both sides have a list of these strings. If they ever disagree the
        // failure is silent: an unrecognised window falls through to the
        // server's default and a course gets metered as a three-minute lesson.
        for window in TimeWindow.allCases {
            let transport = FixtureTransport(.body(
                status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
            ))
            _ = try await makeProvider(transport)
                .suggestTopics(window: window, profile: profile, history: [])
            let sent = try envelope(try XCTUnwrap(transport.requests.first))
            XCTAssertEqual(sent["window"]?.stringValue, window.rawValue)
            XCTAssertEqual(sent["format"]?.stringValue, window.format.rawValue)
        }
        // Spelled out rather than derived, so a rename has to be made here too.
        XCTAssertEqual(TimeWindow.allCases.map(\.rawValue), ["three", "ten", "fifteen", "thirty"])
        XCTAssertEqual(
            LessonFormat.allCases.map(\.rawValue),
            ["oneThing", "explainer", "lesson", "miniCourse"]
        )
    }

    func testNestsTheModelRequestRatherThanFlatteningIt() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.recallJSON)
        ))
        _ = try await makeProvider(transport).generateRecallQuestion(for: fixtureLesson())

        let sent = try envelope(try XCTUnwrap(transport.requests.first))
        let inner = try XCTUnwrap(sent["request"]?.objectValue)
        XCTAssertEqual(inner["model"]?.stringValue, AnthropicAPI.model)
        XCTAssertNotNil(inner["messages"])
        // Flattening would let a future Anthropic field named `topic` become a
        // metering field, and vice versa.
        XCTAssertNil(sent["model"])
        XCTAssertNil(inner["topic"])
    }

    // MARK: - Receipts

    func testOmitsTheReceiptOnTheFreeTier() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
        ))
        _ = try await makeProvider(transport, receipt: nil)
            .suggestTopics(window: .three, profile: profile, history: [])

        let sent = try envelope(try XCTUnwrap(transport.requests.first))
        XCTAssertNil(sent["receipt"])
    }

    func testSendsTheReceiptWhenThereIsOne() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
        ))
        _ = try await makeProvider(transport, receipt: "header.payload.signature")
            .suggestTopics(window: .three, profile: profile, history: [])

        let sent = try envelope(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(sent["receipt"]?.stringValue, "header.payload.signature")
    }

    func testReadsTheReceiptOnEveryCall() async throws {
        // A receipt captured once would keep a lapsed subscriber premium, and a
        // new purchase unrecognised, until the app was relaunched.
        let reads = Counter()
        let transport = FixtureTransport([
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)),
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)),
        ])
        let provider = ProxyProvider(
            transport: transport,
            baseURL: base,
            deviceID: "device-fixture-0001",
            receipt: {
                await reads.increment()
                return "jws"
            },
            sleeper: RecordingSleeper()
        )

        _ = try await provider.suggestTopics(window: .three, profile: profile, history: [])
        _ = try await provider.suggestTopics(window: .three, profile: profile, history: [])

        // Read out first: XCTAssertEqual's arguments are autoclosures, which
        // cannot carry an `await`.
        let count = await reads.value
        XCTAssertEqual(count, 2)
    }

    // MARK: - Streaming

    func testStreamedLessonStillReachesTheReaderInOrder() async throws {
        // The proxy forwards SSE untouched, so the app's side of that contract
        // is unchanged — worth pinning, because a route that re-framed the body
        // would break `RevisionGate` and not the transport.
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
        ])
        let provider = makeProvider(transport)

        let events = try await collect(provider.streamLesson(
            topic: topic, window: .ten, profile: profile, demand: .eager()
        ))

        XCTAssertTrue(events.contains { if case .metadata = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .revisedDelta = $0 { true } else { false } })
        guard case .finished = events.last else {
            return XCTFail("expected the stream to finish with a lesson, got \(String(describing: events.last))")
        }
    }

    func testDeclaresItAcceptsAnEventStreamWhenStreaming() async throws {
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
        ])
        _ = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .ten, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requests.first?.headers["accept"], "text/event-stream")
    }

    // MARK: - The server's refusals

    func testDailyLimitBecomesAReadableRefusal() async throws {
        // Not "Anthropic rejected the request. Check your key in Settings" —
        // which is what a bare 402 used to produce, and which points at a
        // screen a shipped build doesn't have.
        let transport = FixtureTransport(.body(status: 402, text: """
        {"error":{"code":"dailyLimitReached","message":"That's today's free lesson. The next one unlocks tomorrow."}}
        """))
        let provider = makeProvider(transport)

        do {
            _ = try await collect(provider.streamLesson(
                topic: topic, window: .three, profile: profile, demand: .eager()
            ))
            XCTFail("expected a limit error")
        } catch let error as LessonProviderError {
            XCTAssertEqual(
                error,
                .limited(.dailyLesson, message: "That's today's free lesson. The next one unlocks tomorrow.")
            )
            XCTAssertFalse(error.isRetryable)

            let copy = ProviderErrorCopy.presentation(for: error)
            XCTAssertTrue(copy.pointsToPaywall)
            XCTAssertFalse(copy.pointsToSettings)
            XCTAssertEqual(copy.message, "That's today's free lesson. The next one unlocks tomorrow.")
        }
    }

    func testLockedWindowPointsAtThePaywall() async throws {
        let transport = FixtureTransport(.body(status: 402, text: """
        {"error":{"code":"lockedWindow","message":"That length is part of Premium."}}
        """))
        do {
            _ = try await collect(makeProvider(transport).streamLesson(
                topic: topic, window: .thirty, profile: profile, demand: .eager()
            ))
            XCTFail("expected a limit error")
        } catch let error as LessonProviderError {
            XCTAssertEqual(error, .limited(.lockedWindow, message: "That length is part of Premium."))
            XCTAssertTrue(ProviderErrorCopy.presentation(for: error).pointsToPaywall)
        }
    }

    func testCourseCapOffersNoPaywall() async throws {
        // Already paying. A paywall would be asking somebody to buy what they
        // have; the honest answer is that the month has to turn.
        let transport = FixtureTransport(.body(status: 402, text: """
        {"error":{"code":"courseCapReached","message":"You've started every course included this month."}}
        """))
        do {
            _ = try await collect(makeProvider(transport, receipt: "jws").streamLesson(
                topic: topic, window: .thirty, profile: profile, demand: .eager()
            ))
            XCTFail("expected a limit error")
        } catch let error as LessonProviderError {
            let copy = ProviderErrorCopy.presentation(for: error)
            XCTAssertFalse(copy.pointsToPaywall)
            XCTAssertFalse(copy.isRetryable)
        }
    }

    func testSpendCeilingIsRetryable() async throws {
        // A ceiling clears when the month does, or when it is raised. Unlike a
        // tier boundary, trying later genuinely can work.
        // Three identical steps, because retryable means the pipeline will
        // actually retry: `RetryPolicy.standard` makes three attempts. One step
        // would have the fixture run dry and report a transport error instead,
        // which is what the first version of this test was really asserting.
        let ceilingBody = """
        {"error":{"code":"spendCeilingReached","message":"Spare is at its monthly limit. Try again later."}}
        """
        let transport = FixtureTransport(
            Array(repeating: .body(status: 429, text: ceilingBody), count: 3)
        )
        do {
            _ = try await makeProvider(transport)
                .suggestTopics(window: .three, profile: profile, history: [])
            XCTFail("expected a limit error")
        } catch let error as LessonProviderError {
            XCTAssertEqual(
                error,
                .limited(.spendCeiling, message: "Spare is at its monthly limit. Try again later.")
            )
            XCTAssertTrue(error.isRetryable)
            XCTAssertFalse(ProviderErrorCopy.presentation(for: error).pointsToSettings)
        }
    }

    func testVerificationOutageDoesNotReadAsARejectedKey() async throws {
        // A 503 from the proxy means it couldn't reach Apple. Worth retrying,
        // and emphatically not the reader's key — they don't have one.
        let outageBody = """
        {"error":{"code":"verificationUnavailable","message":"Couldn't confirm your subscription. Try again shortly."}}
        """
        let transport = FixtureTransport(
            Array(repeating: .body(status: 503, text: outageBody), count: 3)
        )
        do {
            _ = try await makeProvider(transport, receipt: "jws")
                .suggestTopics(window: .three, profile: profile, history: [])
            XCTFail("expected a limit error")
        } catch let error as LessonProviderError {
            XCTAssertEqual(
                error,
                .limited(.verificationUnavailable, message: "Couldn't confirm your subscription. Try again shortly.")
            )
            XCTAssertFalse(ProviderErrorCopy.presentation(for: error).pointsToSettings)
        }
    }

    func testAnUnrecognisedCodeFallsBackToTheStatus() async throws {
        // A code this build has never heard of must not borrow copy written for
        // a different situation.
        let transport = FixtureTransport(.body(status: 402, text: """
        {"error":{"code":"someFutureLimit","message":"Something new."}}
        """))
        do {
            _ = try await makeProvider(transport)
                .suggestTopics(window: .three, profile: profile, history: [])
            XCTFail("expected an error")
        } catch let error as LessonProviderError {
            XCTAssertEqual(error, .httpStatus(code: 402, message: "Something new."))
        }
    }

    func testAnthropicStyleErrorsAreStillReadAsHTTPFailures() async throws {
        // Anthropic's envelope uses `error.type`, not `error.code`, so the
        // proxy-code path must not swallow a genuine upstream failure.
        // Three steps: `RetryPolicy.standard` makes three attempts.
        let transport = FixtureTransport([
            .body(status: 500, text: HTTPFixtures.overloadedBody),
            .body(status: 500, text: HTTPFixtures.overloadedBody),
            .body(status: 500, text: HTTPFixtures.overloadedBody),
        ])
        do {
            _ = try await makeProvider(transport)
                .suggestTopics(window: .three, profile: profile, history: [])
            XCTFail("expected an error")
        } catch let error as LessonProviderError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("expected httpStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Helpers

    private func fixtureLesson() -> Lesson {
        Lesson(
            title: "Why bridges hum",
            subtitle: "A 10-minute explainer",
            domainTag: "Engineering",
            bodyMarkdown: String(repeating: "word ", count: 1_800),
            surprisingClaim: "Pedestrians synchronised with the sway.",
            deeperAngles: ["Resonance", "Dampers", "Over-damping"]
        )
    }
}

/// Counts calls from a `@Sendable` closure without tripping strict concurrency.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
