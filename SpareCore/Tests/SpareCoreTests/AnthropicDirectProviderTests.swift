import XCTest
@testable import SpareCore

/// Every test here runs against `FixtureTransport`. No network, no API key,
/// no spend — see HTTPFixtures for why that is a hard requirement.
final class AnthropicDirectProviderTests: XCTestCase {

    private let profile = ProfileSnapshot.empty
    private let topic = TopicSuggestion(
        title: "Why bridges hum", hook: "Wind makes steel sing.", domainTag: "Engineering"
    )

    private func makeProvider(
        _ transport: FixtureTransport,
        key: String? = "sk-ant-fixture",
        ledger: any UsageLedger = NoopUsageLedger(),
        sleeper: any Sleeper = RecordingSleeper(),
        retry: RetryPolicy = .standard
    ) -> AnthropicDirectProvider {
        AnthropicDirectProvider(
            transport: transport,
            keyStore: StaticAPIKeyStore(key),
            ledger: ledger,
            sleeper: sleeper,
            // The floor is exercised by `WordFloorTests`; these fixtures are
            // stubs for the transport, not generations. See
            // `Configuration.enforcesWordFloor`.
            configuration: .init(retry: retry, enforcesWordFloor: false),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<LessonStreamEvent, Error>
    ) async throws -> [LessonStreamEvent] {
        var events: [LessonStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func revisedText(_ events: [LessonStreamEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .revisedDelta(_, let piece) = event { text += piece }
        }
    }

    private func draftText(_ events: [LessonStreamEvent]) -> String {
        events.reduce(into: "") { text, event in
            if case .draftDelta(_, let piece) = event { text += piece }
        }
    }

    // MARK: - Missing key

    func testMissingKeyFailsWithoutMakingARequest() async {
        let transport = FixtureTransport([])
        let provider = makeProvider(transport, key: nil)

        do {
            _ = try await provider.suggestTopics(window: .seven, profile: profile, history: [])
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? LessonProviderError, .missingAPIKey)
        }
        XCTAssertEqual(transport.requestCount, 0, "must not hit the network without a key")
    }

    func testEmptyKeyIsTreatedAsMissing() async {
        let transport = FixtureTransport([])
        let provider = makeProvider(transport, key: "")
        do {
            _ = try await provider.suggestTopics(window: .seven, profile: profile, history: [])
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? LessonProviderError, .missingAPIKey)
        }
    }

    // MARK: - Request shape

    func testRequestCarriesKeyVersionSchemaAndCachedSystemPrompt() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
        ))
        let provider = makeProvider(transport)
        _ = try await provider.suggestTopics(window: .seven, profile: profile, history: [])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant-fixture")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")

        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.body))
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5")
        XCTAssertEqual(
            body["output_config"]?["format"]?["type"]?.stringValue, "json_schema",
            "schema-critical calls must use structured outputs"
        )
        XCTAssertEqual(
            body["system"]?.arrayValue?.first?["cache_control"]?["type"]?.stringValue, "ephemeral",
            "the editorial/system prompt must be cached"
        )
        for removed in ["temperature", "top_p", "top_k", "thinking"] {
            XCTAssertNil(body[removed], "must not send \(removed)")
        }
    }

    func testSystemPromptSentIsTheStableEditorialConstant() async throws {
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
        ])
        let provider = makeProvider(transport)
        _ = try await collect(provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        let body = try JSONDecoder().decode(
            JSONValue.self, from: XCTUnwrap(transport.requests.first?.body)
        )
        let system = try XCTUnwrap(body["system"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(system, Prompts.editorialSystemPrompt)
        XCTAssertFalse(
            system.contains("Why bridges hum"),
            "per-lesson detail in the cached prefix would break caching on every call"
        )
    }

    // MARK: - Success path

    func testStreamsLessonThroughBothPasses() async throws {
        let draftBody = "Draft opening sentence about the bridge."
        let revisedBody = "On June 10, 2000, the Millennium Bridge opened and swayed."
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: draftBody))),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: revisedBody))),
        ])
        let provider = makeProvider(transport)

        let events = try await collect(provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 2, "two passes, two calls")
        XCTAssertEqual(draftText(events), draftBody)
        XCTAssertEqual(revisedText(events), revisedBody)

        guard case .finished(let lesson)? = events.last else {
            return XCTFail("stream must end with .finished")
        }
        XCTAssertEqual(lesson.bodyMarkdown, revisedBody, "the revised text is what gets persisted")
    }

    func testRevisionGateNeverShowsDraftTextFromTheLiveProvider() async throws {
        let draftBody = String(repeating: "DRAFTWORD ", count: 400)
        let revisedBody = String(repeating: "revised ", count: 400)
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: draftBody))),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: revisedBody))),
        ])
        let provider = makeProvider(transport)

        var gate = RevisionGate(window: .seven)
        var previous = ""
        for try await event in provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ) {
            gate.apply(event)
            XCTAssertFalse(gate.displayText.contains("DRAFTWORD"), "draft text reached the reader")
            XCTAssertTrue(gate.displayText.hasPrefix(previous), "shown text was rewritten")
            previous = gate.displayText
        }
        XCTAssertEqual(gate.appendOnlyViolations, 0)
        XCTAssertTrue(gate.isRevealed)
    }

    // MARK: - Failure modes

    func testTruncatedStreamIsRetriedThenSucceeds() async throws {
        let transport = FixtureTransport([
            .sse(HTTPFixtures.truncatedStream(json: HTTPFixtures.lessonJSON())),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "Recovered draft."))),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "Recovered revision."))),
        ])
        let sleeper = RecordingSleeper()
        let provider = makeProvider(transport, sleeper: sleeper)

        let events = try await collect(provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 3, "the truncated draft is retried")
        XCTAssertEqual(revisedText(events), "Recovered revision.")
        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [1], "one backoff, at the policy's initial delay")
    }

    func testMalformedJSONIsRetried() async throws {
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: "{not valid json at all")),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "Second attempt draft."))),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "Second attempt revision."))),
        ])
        let provider = makeProvider(transport)

        let events = try await collect(provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))
        XCTAssertEqual(transport.requestCount, 3)
        XCTAssertEqual(revisedText(events), "Second attempt revision.")
    }

    func testRateLimitIsRetriedWithBackoff() async throws {
        let transport = FixtureTransport([
            .body(status: 429, text: HTTPFixtures.rateLimitBody),
            .body(status: 429, text: HTTPFixtures.rateLimitBody),
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)),
        ])
        let sleeper = RecordingSleeper()
        let provider = makeProvider(transport, sleeper: sleeper)

        let suggestions = try await provider.suggestTopics(
            window: .seven, profile: profile, history: []
        )
        XCTAssertEqual(suggestions.count, 5)
        XCTAssertEqual(transport.requestCount, 3)
        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [1, 2], "exponential, not flat")
    }

    func testRetriesAreBoundedByThePolicy() async {
        let transport = FixtureTransport([
            .body(status: 429, text: HTTPFixtures.rateLimitBody),
            .body(status: 429, text: HTTPFixtures.rateLimitBody),
            .body(status: 429, text: HTTPFixtures.rateLimitBody),
            .body(status: 429, text: HTTPFixtures.rateLimitBody),
        ])
        let provider = makeProvider(transport, retry: RetryPolicy(maxAttempts: 3))

        do {
            _ = try await provider.suggestTopics(window: .seven, profile: profile, history: [])
            XCTFail("expected the rate limit to surface")
        } catch {
            XCTAssertEqual(
                error as? LessonProviderError,
                .httpStatus(code: 429, message: "Number of requests has exceeded your rate limit")
            )
        }
        XCTAssertEqual(transport.requestCount, 3, "maxAttempts includes the first try")
    }

    func testNetworkDropSurfacesAfterRetries() async {
        let transport = FixtureTransport([
            .failure(.network("connection lost")),
            .failure(.network("connection lost")),
            .failure(.network("connection lost")),
        ])
        let provider = makeProvider(transport)

        do {
            _ = try await provider.generateRecallQuestion(
                for: MockProvider.fixtureLesson(topic: topic, window: .three)
            )
            XCTFail("expected the network error to surface")
        } catch {
            XCTAssertEqual(error as? LessonProviderError, .network("connection lost"))
        }
        XCTAssertEqual(transport.requestCount, 3)
    }

    func testMidStreamDropAfterEmissionIsNotRetried() async {
        // The revision pass has already put text on the reader's screen;
        // re-running it would append a second copy rather than replace it.
        let partial = HTTPFixtures.messageStart()
            + HTTPFixtures.textDelta(#"{"title":"T","subtitle":"S","domainTag":"D","bodyMarkdown":"visible text"#)
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "draft"))),
            .sseThenError(partial, .network("dropped mid-revision")),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "should never be used"))),
        ])
        let provider = makeProvider(transport)

        do {
            _ = try await collect(provider.streamLesson(
                topic: topic, window: .seven, profile: profile, demand: .eager()
            ))
            XCTFail("expected the dropped revision to surface")
        } catch {
            XCTAssertEqual(error as? LessonProviderError, .network("dropped mid-revision"))
        }
        XCTAssertEqual(
            transport.requestCount, 2,
            "the revision must not be re-run once its text has been shown"
        )
    }

    func testRefusalIsNotRetried() async {
        let transport = FixtureTransport([
            .sse(HTTPFixtures.refusalStream()),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON())),
        ])
        let provider = makeProvider(transport)

        do {
            _ = try await collect(provider.streamLesson(
                topic: topic, window: .seven, profile: profile, demand: .eager()
            ))
            XCTFail("expected a refusal")
        } catch {
            guard case .refused = error as? LessonProviderError else {
                return XCTFail("expected .refused, got \(error)")
            }
        }
        XCTAssertEqual(transport.requestCount, 1, "a refusal is a decision, not a glitch")
    }

    func testAuthFailureIsNotRetried() async {
        let transport = FixtureTransport([
            .body(status: 401, text: #"{"type":"error","error":{"message":"invalid key"}}"#),
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)),
        ])
        let provider = makeProvider(transport)

        do {
            _ = try await provider.suggestTopics(window: .seven, profile: profile, history: [])
            XCTFail("expected missingAPIKey")
        } catch {
            XCTAssertEqual(error as? LessonProviderError, .missingAPIKey)
        }
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testOverloadedStreamErrorEventIsRetryable() async throws {
        let transport = FixtureTransport([
            .sse(HTTPFixtures.errorStream(type: "overloaded_error", message: "Overloaded")),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "draft"))),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "revision"))),
        ])
        let provider = makeProvider(transport)

        let events = try await collect(provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))
        XCTAssertEqual(revisedText(events), "revision")
        XCTAssertEqual(transport.requestCount, 3)
    }

    // MARK: - Usage ledger

    func testEveryCallIsWrittenToTheLedger() async throws {
        let ledger = InMemoryUsageLedger()
        let transport = FixtureTransport([
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "draft"), inputTokens: 1_000, outputTokens: 500)),
            .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: "revision"), inputTokens: 1_500, outputTokens: 600)),
        ])
        let provider = makeProvider(transport, ledger: ledger)

        _ = try await collect(provider.streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        let events = await ledger.events
        XCTAssertEqual(events.map(\.kind), [.lessonDraft, .lessonRevision])
        XCTAssertEqual(events[0].usage.inputTokens, 1_000)
        XCTAssertEqual(events[0].usage.outputTokens, 500)
        XCTAssertEqual(events[1].usage.inputTokens, 1_500)
        for event in events {
            XCTAssertEqual(event.model, "claude-opus-5")
            XCTAssertGreaterThan(event.estimatedCostUSD, 0)
        }
    }

    func testCachedReadsAreLedgeredAndCostLess() async throws {
        let ledger = InMemoryUsageLedger()
        let transport = FixtureTransport(.body(
            status: 200,
            text: """
            {"content":[{"type":"text","text":\(HTTPFixtures.jsonEncoded(HTTPFixtures.recallJSON))}],
             "usage":{"input_tokens":10,"output_tokens":100,
                      "cache_creation_input_tokens":0,"cache_read_input_tokens":2000}}
            """
        ))
        let provider = makeProvider(transport, ledger: ledger)
        _ = try await provider.generateRecallQuestion(
            for: MockProvider.fixtureLesson(topic: topic, window: .three)
        )

        // Awaited into a local first: XCTUnwrap takes an autoclosure, which
        // can't carry an `await`.
        let recorded = await ledger.events
        let event = try XCTUnwrap(recorded.first)
        XCTAssertEqual(event.usage.cacheReadInputTokens, 2_000)
        let uncached = CostEstimator.cost(of: TokenUsage(inputTokens: 2_010, outputTokens: 100))
        XCTAssertLessThan(event.estimatedCostUSD, uncached, "cache reads must bill cheaper")
    }

    // MARK: - Suggestions

    func testSuggestionsAreValidatedAndRepaired() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)
        ))
        let provider = makeProvider(transport)
        let suggestions = try await provider.suggestTopics(
            window: .seven, profile: profile, history: []
        )
        XCTAssertEqual(suggestions.count, 5)
        XCTAssertEqual(suggestions.filter(\.isWildcard).count, 1)
        XCTAssertTrue(SuggestionValidator.isAcceptable(suggestions))
    }

    func testStructurallyInvalidSuggestionsTriggerOneRegeneration() async throws {
        let broken = """
        {"suggestions":[
          {"title":"A","hook":"h","domainTag":"History","isWildcard":false},
          {"title":"B","hook":"h","domainTag":"History","isWildcard":false}
        ]}
        """
        let transport = FixtureTransport([
            .body(status: 200, text: HTTPFixtures.messageBody(json: broken)),
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.suggestionsJSON)),
        ])
        let provider = makeProvider(transport)

        let suggestions = try await provider.suggestTopics(
            window: .seven, profile: profile, history: []
        )
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(suggestions.count, 5)
    }

    func testSuggestionRegenerationIsCappedAtOne() async throws {
        let broken = """
        {"suggestions":[{"title":"A","hook":"h","domainTag":"History","isWildcard":false}]}
        """
        let transport = FixtureTransport([
            .body(status: 200, text: HTTPFixtures.messageBody(json: broken)),
            .body(status: 200, text: HTTPFixtures.messageBody(json: broken)),
            .body(status: 200, text: HTTPFixtures.messageBody(json: broken)),
        ])
        let provider = makeProvider(transport)

        _ = try await provider.suggestTopics(window: .seven, profile: profile, history: [])
        XCTAssertEqual(transport.requestCount, 2, "must not chase a perfect set indefinitely")
    }

    // MARK: - Recall and go deeper

    func testRecallQuestionDecodes() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.recallJSON)
        ))
        let provider = makeProvider(transport)
        let question = try await provider.generateRecallQuestion(
            for: MockProvider.fixtureLesson(topic: topic, window: .three)
        )
        XCTAssertEqual(question.distractors.count, 3)
        XCTAssertFalse(question.answer.isEmpty)
    }

    func testPostLessonTestDecodesExactlyThreeQuestions() async throws {
        let transport = FixtureTransport(.body(
            status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.postLessonTestJSON)
        ))
        let ledger = InMemoryUsageLedger()
        let provider = makeProvider(transport, ledger: ledger)
        let questions = try await provider.generatePostLessonTest(
            for: MockProvider.fixtureLesson(topic: topic, window: .three),
            window: .three
        )
        XCTAssertEqual(questions.count, 3)
        for question in questions {
            XCTAssertEqual(question.distractors.count, 3)
            XCTAssertFalse(question.answer.isEmpty)
        }
        let kinds = await ledger.events.map(\.kind)
        XCTAssertEqual(kinds, [.postLessonTest])
    }

    func testPostLessonTestTruncatesAnOverLongResponseRatherThanFail() async throws {
        let overLong = """
        {"questions":[
          {"question":"Q1","answer":"A1","distractors":["D1","D2","D3"],"explanation":"E1"},
          {"question":"Q2","answer":"A2","distractors":["D1","D2","D3"],"explanation":"E2"},
          {"question":"Q3","answer":"A3","distractors":["D1","D2","D3"],"explanation":"E3"},
          {"question":"Q4","answer":"A4","distractors":["D1","D2","D3"],"explanation":"E4"}
        ]}
        """
        let transport = FixtureTransport(.body(status: 200, text: HTTPFixtures.messageBody(json: overLong)))
        let provider = makeProvider(transport)
        let questions = try await provider.generatePostLessonTest(
            for: MockProvider.fixtureLesson(topic: topic, window: .three),
            window: .three
        )
        XCTAssertEqual(questions.count, 3)
    }

    func testGoDeeperRunsBothPasses() async throws {
        let transport = FixtureTransport([
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.lessonJSON(body: "deeper draft"))),
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.lessonJSON(body: "deeper revision"))),
        ])
        let ledger = InMemoryUsageLedger()
        let provider = makeProvider(transport, ledger: ledger)

        let lesson = try await provider.goDeeper(
            from: MockProvider.fixtureLesson(topic: topic, window: .seven),
            angle: DeeperAngle(text: "How dampers work"),
            window: .seven,
            profile: profile
        )
        XCTAssertEqual(lesson.bodyMarkdown, "deeper revision")
        XCTAssertEqual(transport.requestCount, 2)
        let kinds = await ledger.events.map(\.kind)
        XCTAssertEqual(kinds, [.goDeeperDraft, .goDeeperRevision])
    }
}
