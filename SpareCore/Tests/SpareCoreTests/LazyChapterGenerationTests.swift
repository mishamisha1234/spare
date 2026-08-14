import XCTest
@testable import SpareCore

/// A 45-minute mini-course is an outline call plus two calls per chapter —
/// 13 API calls if every chapter is generated. A reader who stops at chapter 2
/// must not pay for chapters 3–6, so these tests count requests rather than
/// just checking that output looks right.
/// Counts events from inside a detached `Task`. An actor rather than a
/// captured `var`: mutating a local from a concurrently-running closure is a
/// data race, which Swift 6 rejects outright.
private actor ChapterCounter {
    private(set) var revisedChapters = 0

    func countRevised() {
        revisedChapters += 1
    }
}

final class LazyChapterGenerationTests: XCTestCase {

    private let profile = ProfileSnapshot.empty
    private let topic = TopicSuggestion(
        title: "Why planes are safe", hook: "Every rule was written after a crash.",
        domainTag: "Engineering"
    )

    /// Outline + enough chapter draft/revision pairs to satisfy any test that
    /// runs to completion.
    private func fullCourseSteps(chapters: Int = 6) -> [FixtureTransport.Step] {
        // The outline is a plain (non-streaming) call — it's small and nothing
        // renders from it — so it needs a `.body` fixture, not `.sse`.
        var steps: [FixtureTransport.Step] = [
            .body(
                status: 200,
                text: HTTPFixtures.messageBody(json: HTTPFixtures.outlineJSON(chapterCount: chapters))
            )
        ]
        for index in 0..<chapters {
            steps.append(.sse(HTTPFixtures.stream(
                json: HTTPFixtures.chapterJSON(
                    heading: "Chapter theme \(index + 1)", body: "Draft body \(index + 1)."
                )
            )))
            steps.append(.sse(HTTPFixtures.stream(
                json: HTTPFixtures.chapterJSON(
                    heading: "Chapter theme \(index + 1)", body: "Revised body \(index + 1)."
                )
            )))
        }
        return steps
    }

    private func makeProvider(
        _ transport: FixtureTransport, ledger: any UsageLedger = NoopUsageLedger()
    ) -> AnthropicDirectProvider {
        AnthropicDirectProvider(
            transport: transport,
            keyStore: StaticAPIKeyStore("sk-ant-fixture"),
            ledger: ledger,
            sleeper: RecordingSleeper()
        )
    }

    // MARK: - Laziness

    func testReaderWhoStopsEarlyNeverTriggersLaterChapters() async throws {
        let transport = FixtureTransport(fullCourseSteps())
        let provider = makeProvider(transport)
        // Default prefetch of 1: reader in chapter 0 clears chapters 0 and 1.
        let demand = ChapterDemand()

        let stream = provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: demand
        )

        let counter = ChapterCounter()
        let task = Task {
            for try await event in stream {
                if case .revisedChapterFinished = event { await counter.countRevised() }
            }
        }

        // Give generation room to run as far as the demand allows, then stop.
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.result

        let revisedChapters = await counter.revisedChapters
        XCTAssertEqual(revisedChapters, 2, "chapters 0 and 1 only — the prefetch window")
        XCTAssertEqual(
            transport.requestCount, 5,
            "1 outline + 2 chapters x 2 passes; chapters 3-6 were never requested"
        )
    }

    func testAdvancingTheReaderReleasesExactlyOneMoreChapter() async throws {
        let transport = FixtureTransport(fullCourseSteps())
        let provider = makeProvider(transport)
        let demand = ChapterDemand()

        let stream = provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: demand
        )
        let task = Task {
            for try await _ in stream {}
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(transport.requestCount, 5, "outline + chapters 0 and 1")

        demand.readerReached(chapter: 1)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(transport.requestCount, 7, "chapter 2 released, nothing beyond it")

        task.cancel()
        _ = await task.result
    }

    func testEagerDemandGeneratesTheWholeCourse() async throws {
        let transport = FixtureTransport(fullCourseSteps())
        let provider = makeProvider(transport)

        var events: [LessonStreamEvent] = []
        for try await event in provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: .eager()
        ) {
            events.append(event)
        }

        XCTAssertEqual(transport.requestCount, 13, "1 outline + 6 chapters x 2 passes")
        guard case .finished(let lesson)? = events.last else {
            return XCTFail("expected .finished")
        }
        XCTAssertEqual(lesson.deeperAngles.count, 3, "Completion needs three angles")
        XCTAssertFalse(lesson.title.isEmpty)
        XCTAssertFalse(lesson.surprisingClaim.isEmpty)
    }

    func testCancellingTheStreamStopsFurtherCalls() async throws {
        let transport = FixtureTransport(fullCourseSteps())
        let provider = makeProvider(transport)
        let demand = ChapterDemand.eager()

        // Built outside the Task: `topic` and `profile` are instance
        // properties, so referencing them inside would capture the
        // non-Sendable XCTestCase.
        let stream = provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: demand
        )
        let task = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        task.cancel()
        _ = await task.result

        let afterCancel = transport.requestCount
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.requestCount, afterCancel, "no calls after cancellation")
    }

    // MARK: - Assembled output

    func testChapterTextCarriesItsHeadingBeforeItsBody() async throws {
        let transport = FixtureTransport(fullCourseSteps(chapters: 6))
        let provider = makeProvider(transport)

        var revised = ""
        for try await event in provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: .eager()
        ) {
            if case .revisedDelta(_, let text) = event { revised += text }
        }

        XCTAssertTrue(revised.hasPrefix("## Chapter 1: Chapter theme 1\n\n"))
        XCTAssertTrue(revised.contains("## Chapter 2: Chapter theme 2"))
        guard let headingIndex = revised.range(of: "## Chapter 1:"),
              let bodyIndex = revised.range(of: "Revised body 1.") else {
            return XCTFail("missing heading or body")
        }
        XCTAssertLessThan(headingIndex.lowerBound, bodyIndex.lowerBound)
    }

    /// The canonical body in `.finished` must match what the gate already
    /// committed, or the gate rejects it and the reader's text and the stored
    /// text diverge.
    func testFinishedBodyMatchesWhatTheGateAlreadyShowed() async throws {
        let transport = FixtureTransport(fullCourseSteps())
        let provider = makeProvider(transport)

        var gate = RevisionGate(window: .fortyFive)
        for try await event in provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: .eager()
        ) {
            gate.apply(event)
        }

        XCTAssertEqual(gate.appendOnlyViolations, 0, "canonical body contradicted shown text")
        let lesson = try XCTUnwrap(gate.finalLesson)
        XCTAssertEqual(gate.displayText, lesson.bodyMarkdown)
    }

    func testOutlineIsLedgeredSeparatelyFromChapters() async throws {
        let ledger = InMemoryUsageLedger()
        let transport = FixtureTransport(fullCourseSteps(chapters: 6))
        let provider = makeProvider(transport, ledger: ledger)

        for try await _ in provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: .eager()
        ) {}

        let kinds = await ledger.events.map(\.kind)
        XCTAssertEqual(kinds.first, .courseOutline)
        XCTAssertEqual(kinds.filter { $0 == .chapterDraft }.count, 6)
        XCTAssertEqual(kinds.filter { $0 == .chapterRevision }.count, 6)
    }

    // MARK: - MockProvider honours the same contract

    func testMockProviderIsAlsoLazy() async throws {
        let provider = MockProvider(simulateLatency: false)
        let demand = ChapterDemand()
        let counter = ChapterCounter()

        let stream = provider.streamLesson(
            topic: topic, window: .fortyFive, profile: profile, demand: demand
        )
        let task = Task {
            for try await event in stream {
                if case .revisedChapterFinished = event { await counter.countRevised() }
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result

        let revisedChapters = await counter.revisedChapters
        XCTAssertEqual(revisedChapters, 2, "offline provider must respect back-pressure too")
    }
}
