import XCTest
@testable import SpareCore

/// The word floor, from the prompt down to the stream the reader sees.
///
/// The failure this exists to stop is not a crash and nobody would report it.
/// Across the last comparison batch, one 15-minute lesson in five reached its
/// word budget, and one came back at 1,555 words against a 2,400-word floor —
/// about eight minutes of reading, sold as fifteen. Time is the product's whole
/// promise, and it was being broken at exactly the lengths people pay for.
///
/// So: under 90% of the floor is not a finding to log, it is a generation that
/// did not happen. Not served, not cached, retried.
final class WordFloorTests: XCTestCase {

    private let topic = TopicSuggestion(
        title: "Why bridges hum", hook: "Wind makes steel sing.", domainTag: "Engineering"
    )
    private let profile = ProfileSnapshot(interests: ["Engineering"], work: "Logistics")

    /// Enforcing, unlike the transport-level suites. See
    /// `GenerationPipeline.Configuration.enforcesWordFloor`.
    private func makeProvider(
        _ transport: FixtureTransport,
        retries: Int = 1
    ) -> AnthropicDirectProvider {
        AnthropicDirectProvider(
            transport: transport,
            keyStore: StaticAPIKeyStore("sk-ant-fixture"),
            sleeper: RecordingSleeper(),
            configuration: .init(wordFloorRetries: retries, enforcesWordFloor: true)
        )
    }

    /// Real words, whitespace-separated, because that is what the word count
    /// measures. One repeated token counts as one word however long it is.
    private func filler(words: Int) -> String {
        let vocabulary = [
            "the", "bridge", "swayed", "because", "walkers", "fell", "into", "step",
            "and", "resonance", "did", "the", "rest", "on", "a", "cold", "morning",
        ]
        return (0..<words).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")
    }

    private func lessonStream(words: Int) -> FixtureTransport.Step {
        .sse(HTTPFixtures.stream(json: HTTPFixtures.lessonJSON(body: filler(words: words))))
    }

    private func collect(
        _ stream: AsyncThrowingStream<LessonStreamEvent, Error>
    ) async throws -> [LessonStreamEvent] {
        var events: [LessonStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func restarts(_ events: [LessonStreamEvent]) -> Int {
        events.filter { if case .revisionRestarted = $0 { return true } else { return false } }.count
    }

    // MARK: - The happy path is untouched

    func testAnInBudgetLessonMakesExactlyTwoCalls() async throws {
        // 1,200 words against the 7-minute budget of 1,100–1,400: nothing to
        // retry, and the check must not cost a call when it passes.
        let transport = FixtureTransport([lessonStream(words: 1_200), lessonStream(words: 1_200)])
        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 2, "two passes, two calls")
        XCTAssertEqual(restarts(events), 0)
    }

    func testTightIsServed() async throws {
        // 1,050 words against a 1,100 floor: under budget, over the 990 hard
        // floor. Regenerating this would spend a whole pass to buy the reader
        // a handful of seconds, and the reader would wait for it.
        let transport = FixtureTransport([lessonStream(words: 1_050), lessonStream(words: 1_050)])
        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(restarts(events), 0)
    }

    // MARK: - The draft gate

    func testAShortDraftIsRetriedWithoutTheReaderSeeingAnything() async throws {
        // Pass 1 is never displayed, so its retry costs a call and nothing else.
        let transport = FixtureTransport([
            lessonStream(words: 400),    // draft, short
            lessonStream(words: 1_200),  // draft again, fine
            lessonStream(words: 1_200),  // revision
        ])
        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 3)
        XCTAssertEqual(restarts(events), 0, "a draft retry is invisible: nothing was shown to take back")
    }

    func testAPersistentlyShortDraftStillGoesToRevision() async throws {
        // A short draft is not yet a failed lesson. The revision prompt is now
        // told that under the floor means unfinished, so refusing at the draft
        // would throw away lessons the next call fixes — which is exactly what
        // happens here.
        let transport = FixtureTransport([
            lessonStream(words: 400),    // draft, short
            lessonStream(words: 420),    // draft again, still short
            lessonStream(words: 1_200),  // revision takes it further
        ])
        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 3)
        guard case .finished(let lesson)? = events.last else {
            return XCTFail("stream must end with .finished")
        }
        XCTAssertEqual(lesson.wordCount, 1_200)
    }

    // MARK: - The revision gate

    func testAShortRevisionIsWithdrawnAndRunAgain() async throws {
        let transport = FixtureTransport([
            lessonStream(words: 1_200),  // draft
            lessonStream(words: 700),    // revision, well under the 990 hard floor
            lessonStream(words: 1_200),  // revision again
        ])
        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(transport.requestCount, 3)
        XCTAssertEqual(restarts(events), 1, "the short revision must be taken back, not appended to")

        guard case .finished(let lesson)? = events.last else {
            return XCTFail("stream must end with .finished")
        }
        XCTAssertEqual(lesson.wordCount, 1_200)
    }

    /// The retry has to say what was wrong with the last attempt, or it is the
    /// same request twice at the same price.
    func testTheRetryTellsTheModelWhatItProduced() async throws {
        let transport = FixtureTransport([
            lessonStream(words: 1_200),
            lessonStream(words: 700),
            lessonStream(words: 1_200),
        ])
        _ = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ))

        let bodies = try transport.requests.map { request -> String in
            let json = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.body))
            return json["messages"]?.arrayValue?.first?["content"]?
                .arrayValue?.first?["text"]?.stringValue ?? ""
        }
        XCTAssertEqual(bodies.count, 3)
        XCTAssertFalse(bodies[1].contains("previous revision"), "the first revision has nothing to report")
        XCTAssertTrue(bodies[2].contains("700 words"), "the retry must name the shortfall")
        XCTAssertTrue(bodies[2].contains("1100-word floor"))
    }

    /// A withdrawal is the one time displayed text may shrink, and the gate has
    /// to treat it as a rewind rather than as an append-only violation.
    func testTheGateRewindsRatherThanRecordingAViolation() async throws {
        let transport = FixtureTransport([
            lessonStream(words: 1_200),
            lessonStream(words: 700),
            lessonStream(words: 1_200),
        ])
        var gate = RevisionGate(window: .seven)
        var sawTextBeforeTheRestart = false

        for try await event in makeProvider(transport).streamLesson(
            topic: topic, window: .seven, profile: profile, demand: .eager()
        ) {
            if case .revisionRestarted = event {
                sawTextBeforeTheRestart = !gate.displayText.isEmpty
            }
            gate.apply(event)
            if case .revisionRestarted = event {
                XCTAssertEqual(gate.displayText, "", "the withdrawn attempt is still on screen")
                XCTAssertFalse(gate.isRevealed, "an unchaptered rewind goes back behind the curtain")
            }
        }

        XCTAssertTrue(sawTextBeforeTheRestart, "the test proves nothing if nothing was shown")
        XCTAssertEqual(gate.revisionRestarts, 1)
        XCTAssertEqual(gate.appendOnlyViolations, 0, "a rewind is not a violation")
        XCTAssertEqual(gate.finalLesson?.wordCount, 1_200)
        XCTAssertFalse(gate.displayText.isEmpty)
    }

    // MARK: - Giving up

    func testItRefusesRatherThanServingAShortLesson() async throws {
        // Both revision attempts come back short. Serving the better of two bad
        // answers is the failure this whole check exists to stop.
        let transport = FixtureTransport([
            lessonStream(words: 1_200),
            lessonStream(words: 700),
            lessonStream(words: 950),
        ])

        do {
            _ = try await collect(makeProvider(transport).streamLesson(
                topic: topic, window: .seven, profile: profile, demand: .eager()
            ))
            XCTFail("a lesson two-thirds the length it was sold as must not be served")
        } catch let error as LessonProviderError {
            guard case .underWordFloor(let words, let floor) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(words, 950)
            XCTAssertEqual(floor, 1_100)
            XCTAssertFalse(error.isRetryable, "the pipeline has already spent its retries")
        }
    }

    func testTheRetryBudgetIsRespected() async throws {
        // Zero retries: one short revision and it is over. The bound matters —
        // each attempt is a full pass at full price, and the server counts them.
        let transport = FixtureTransport([lessonStream(words: 1_200), lessonStream(words: 700)])

        do {
            _ = try await collect(makeProvider(transport, retries: 0).streamLesson(
                topic: topic, window: .seven, profile: profile, demand: .eager()
            ))
            XCTFail("expected a refusal")
        } catch let error as LessonProviderError {
            guard case .underWordFloor = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(transport.requestCount, 2, "no retry was budgeted, so none was made")
        }
    }

    // MARK: - Chapters are measured as chapters

    /// A chapter of a 30-minute course is 1,500 words, not 6,000. Measuring it
    /// against the course's floor would refuse every chapter ever written — the
    /// same mistake that once handed a chapter revision the whole course's
    /// budget and broke every 30-minute course.
    func testAChapterIsMeasuredAgainstAChaptersBudget() async throws {
        let chapterCount = TimeWindow.thirty.format.chapterCount
        var steps: [FixtureTransport.Step] = [
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.outlineJSON()))
        ]
        // 1,450 words per chapter: far under the course's 6,000 floor, and over
        // the 1,350 a chapter is actually held to.
        for _ in 0..<(chapterCount * 2) {
            steps.append(.sse(HTTPFixtures.stream(
                json: HTTPFixtures.chapterJSON(body: filler(words: 1_450))
            )))
        }
        let transport = FixtureTransport(steps)

        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .thirty, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(restarts(events), 0, "a full-length chapter must not be refused")
        XCTAssertEqual(transport.requestCount, 1 + chapterCount * 2)
    }

    func testAShortChapterIsWithdrawnAndRunAgain() async throws {
        let chapterCount = TimeWindow.thirty.format.chapterCount
        var steps: [FixtureTransport.Step] = [
            .body(status: 200, text: HTTPFixtures.messageBody(json: HTTPFixtures.outlineJSON()))
        ]
        // Chapter 1: a full draft, a short revision, then a full one.
        steps.append(.sse(HTTPFixtures.stream(json: HTTPFixtures.chapterJSON(body: filler(words: 1_450)))))
        steps.append(.sse(HTTPFixtures.stream(json: HTTPFixtures.chapterJSON(body: filler(words: 700)))))
        steps.append(.sse(HTTPFixtures.stream(json: HTTPFixtures.chapterJSON(body: filler(words: 1_450)))))
        for _ in 0..<((chapterCount - 1) * 2) {
            steps.append(.sse(HTTPFixtures.stream(
                json: HTTPFixtures.chapterJSON(body: filler(words: 1_450))
            )))
        }
        let transport = FixtureTransport(steps)

        let events = try await collect(makeProvider(transport).streamLesson(
            topic: topic, window: .thirty, profile: profile, demand: .eager()
        ))

        XCTAssertEqual(restarts(events), 1)
        // The heading has to survive the rewind: the withdrawn attempt took its
        // own header back with it, so the retry must emit one again.
        guard case .finished(let course)? = events.last else {
            return XCTFail("stream must end with .finished")
        }
        let headings = course.bodyMarkdown
            .split(separator: "\n")
            .filter { $0.hasPrefix(LessonFormat.chapterHeadingPrefix) }
        XCTAssertEqual(headings.count, chapterCount, "a rewound chapter lost its heading")
    }
}
