import XCTest
@testable import SpareCore

/// The client half of "a test is generated once per lesson, not once per
/// reader".
///
/// The number this exists to avoid: a 30-minute course read by two hundred
/// premium users, at roughly $0.20 of test generation each, is $40 of tests on
/// a lesson that cost $1.40 to write.
final class LessonAttachmentsTests: XCTestCase {

    private let identity = LessonIdentity(
        window: .seven, topic: "How standard time was imposed", interest: "History"
    )

    private func question(_ index: Int) -> RecallQuestion {
        RecallQuestion(
            question: "Question \(index)?",
            answer: "Answer \(index)",
            distractors: ["Wrong \(index)a", "Wrong \(index)b", "Wrong \(index)c"],
            explanation: "Because of reason \(index)."
        )
    }

    private func store(_ transport: FixtureTransport) -> ProxyAttachmentStore {
        ProxyAttachmentStore(
            transport: transport,
            baseURL: URL(string: "https://proxy.example")!,
            deviceID: "device-fixture-0001"
        )
    }

    // MARK: - Reading

    func testDecodesAStoredRecallQuestionAndTest() async throws {
        let payload = """
        {"recall":{"question":"Q?","answer":"A","distractors":["d1","d2","d3"],"explanation":"E"},
         "test":[{"question":"T1?","answer":"A1","distractors":["d1","d2","d3"],"explanation":"E1"}]}
        """
        let transport = FixtureTransport(.body(status: 200, text: payload))

        let attachments = try await store(transport).attachments(for: identity)

        XCTAssertEqual(attachments?.recall.question, "Q?")
        XCTAssertEqual(attachments?.test.count, 1)
        XCTAssertEqual(attachments?.hasTest, true)
    }

    /// 404 is "not attached yet", which is a state and not a failure: the
    /// reader may have arrived between the lesson being cached and its
    /// attachments landing. Anything else is thrown, because a reader silently
    /// losing tomorrow's question is the kind of breakage nobody reports.
    func testNothingAttachedYetIsNilRatherThanAnError() async throws {
        let transport = FixtureTransport(.body(
            status: 404, text: #"{"error":{"code":"noAttachments","message":"Nothing."}}"#
        ))
        let attachments = try await store(transport).attachments(for: identity)
        XCTAssertNil(attachments)
    }

    func testAServerErrorSurfacesRatherThanReadingAsEmpty() async {
        let transport = FixtureTransport(.body(
            status: 500, text: #"{"error":{"code":"upstreamUnavailable","message":"Down."}}"#
        ))
        do {
            _ = try await store(transport).attachments(for: identity)
            XCTFail("a 500 must not read as 'nothing attached'")
        } catch {
            XCTAssertTrue(error is LessonProviderError, "\(error)")
        }
    }

    // MARK: - Writing

    func testTheUploadCarriesTheIdentityThePoolKeysOn() async throws {
        let transport = FixtureTransport(.body(status: 200, text: #"{"stored":true}"#))
        let attachments = LessonAttachments(
            recall: question(0), test: (1...4).map(question)
        )

        try await store(transport).attach(attachments, for: identity)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.url.absoluteString.hasSuffix("/v1/attach"))
        XCTAssertEqual(request.headers["x-spare-device"], "device-fixture-0001")

        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.body))
        // The same four strings the generation call sent. A lesson filed under
        // a different topic than it was requested under can never be found
        // again, silently and forever.
        XCTAssertEqual(body["window"]?.stringValue, "seven")
        XCTAssertEqual(body["format"]?.stringValue, "explainer")
        XCTAssertEqual(body["topic"]?.stringValue, "How standard time was imposed")
        XCTAssertEqual(body["interest"]?.stringValue, "History")
        XCTAssertEqual(body["attachments"]?["test"]?.arrayValue?.count, 4)
    }

    func testARefusedUploadThrows() async {
        // The server refuses an attachment from a device that did not generate
        // the lesson, and a wrong-shaped test. Neither is worth retrying, but
        // both are worth surfacing rather than swallowing.
        let transport = FixtureTransport(.body(
            status: 403, text: #"{"error":{"code":"notTheGenerator","message":"No."}}"#
        ))
        do {
            try await store(transport).attach(
                LessonAttachments(recall: question(0)), for: identity
            )
            XCTFail("a refused upload must not look like a stored one")
        } catch {
            XCTAssertTrue(error is LessonProviderError, "\(error)")
        }
    }

    // MARK: - The offline answer

    /// Not a stub. On the direct route and the mock there is exactly one
    /// reader, so there is no shared pool to attach to and generating per
    /// reader is the only thing that makes sense.
    func testTheNoOpStoreAttachesNothingAndFindsNothing() async throws {
        let noop = NoAttachmentStore()
        try await noop.attach(LessonAttachments(recall: question(0)), for: identity)
        let found = try await noop.attachments(for: identity)
        XCTAssertNil(found)
    }

    // MARK: - Counts

    /// The count the client is told, the count the schema asks for, and the
    /// count the server will accept are one number.
    func testQuestionCountsMatchTheSpec() {
        XCTAssertEqual(TimeWindow.one.testQuestionCount, 2)
        XCTAssertEqual(TimeWindow.three.testQuestionCount, 3)
        XCTAssertEqual(TimeWindow.seven.testQuestionCount, 4)
        XCTAssertEqual(TimeWindow.fifteen.testQuestionCount, 5)
        XCTAssertEqual(TimeWindow.thirty.testQuestionCount, 10)
    }

    func testThePromptAndTheSchemaAskForTheSameNumber() {
        for window in TimeWindow.allCases {
            let count = window.testQuestionCount
            let prompt = Prompts.postLessonTestTaskPrompt(
                lesson: MockProvider.fixtureLesson(
                    topic: TopicSuggestion(title: "T", hook: "h", domainTag: "History"),
                    window: window
                ),
                questionCount: count
            )
            XCTAssertTrue(prompt.contains("exactly \(count) questions"), "\(window): \(prompt.prefix(80))")

            let schema = Schemas.postLessonTest(questionCount: count)
            let described = schema["properties"]?["questions"]?["description"]?.stringValue ?? ""
            XCTAssertTrue(described.contains("Exactly \(count)"), "\(window): \(described)")
        }
    }

    /// The number must not be in the cached prefix, or there are five cached
    /// prefixes instead of one and the cache is doing nothing.
    func testTheCachedSystemPromptCarriesNoCount() {
        let prompt = Prompts.postLessonTestSystemPrompt
        for count in TimeWindow.allCases.map(\.testQuestionCount) {
            XCTAssertFalse(prompt.contains("\(count) questions"), "count \(count) leaked into the cached prefix")
        }
        XCTAssertFalse(prompt.contains("three recall questions"))
    }
}
