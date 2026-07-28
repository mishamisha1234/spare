import XCTest
@testable import SpareCore

final class AnthropicWireTests: XCTestCase {

    // MARK: - Model constant

    func testGenerationModelIsPinnedInOnePlace() {
        XCTAssertEqual(AnthropicAPI.model, "claude-opus-5")
        XCTAssertEqual(AnthropicAPI.versionHeader, "2023-06-01")
        XCTAssertNotNil(AnthropicAPI.messagesURL)
        XCTAssertEqual(AnthropicAPI.messagesURL?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testMaxTokensLeavesRoomForEveryBudget() {
        for window in TimeWindow.allCases {
            // Roughly 1.4 tokens per word, plus thinking headroom.
            let neededForProse = Int(Double(window.chapterWordBudget.upperBound) * 1.4)
            XCTAssertGreaterThan(
                AnthropicAPI.maxTokens(for: window),
                neededForProse,
                "\(window) max_tokens leaves no headroom"
            )
        }
    }

    // MARK: - Request body shape

    private func body(_ request: MessagesRequest) throws -> JSONValue {
        let data = try request.encodedBody()
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testMinimalRequestShape() throws {
        let request = MessagesRequest(maxTokens: 1_000, messages: [.user("Hello")])
        let json = try body(request)
        XCTAssertEqual(json["model"]?.stringValue, "claude-opus-5")
        XCTAssertEqual(json["max_tokens"]?.intValue, 1_000)
        XCTAssertEqual(json["messages"]?.arrayValue?.count, 1)
        XCTAssertEqual(json["messages"]?.arrayValue?[0]["role"]?.stringValue, "user")
        XCTAssertEqual(
            json["messages"]?.arrayValue?[0]["content"]?.arrayValue?[0]["text"]?.stringValue,
            "Hello"
        )
    }

    /// These are rejected on current models; a regression here is a 400 in prod.
    func testRequestOmitsRemovedParameters() throws {
        let request = MessagesRequest(
            maxTokens: 1_000,
            system: "sys",
            messages: [.user("Hi")],
            stream: true,
            effort: .high,
            outputSchema: Schemas.lesson
        )
        let json = try body(request)
        for removed in ["temperature", "top_p", "top_k", "thinking", "budget_tokens"] {
            XCTAssertNil(json[removed], "request must not send \(removed)")
        }
    }

    func testNoAssistantPrefillIsEverSent() throws {
        let request = MessagesRequest(maxTokens: 1_000, messages: [.user("Hi")])
        let roles = try body(request)["messages"]?.arrayValue?.compactMap { $0["role"]?.stringValue }
        XCTAssertEqual(roles, ["user"], "assistant prefill is rejected on current models")
    }

    func testSystemPromptIsCachedByDefault() throws {
        let request = MessagesRequest(maxTokens: 100, system: "big shared prompt", messages: [.user("Hi")])
        let system = try XCTUnwrap(try body(request)["system"]?.arrayValue?.first)
        XCTAssertEqual(system["type"]?.stringValue, "text")
        XCTAssertEqual(system["text"]?.stringValue, "big shared prompt")
        XCTAssertEqual(system["cache_control"]?["type"]?.stringValue, "ephemeral")
    }

    func testCachingCanBeDisabled() throws {
        let request = MessagesRequest(
            maxTokens: 100, system: "s", messages: [.user("Hi")], cacheSystemPrompt: false
        )
        let system = try XCTUnwrap(try body(request)["system"]?.arrayValue?.first)
        XCTAssertNil(system["cache_control"])
    }

    func testNoSystemKeyWhenThereIsNoSystemPrompt() throws {
        let request = MessagesRequest(maxTokens: 100, messages: [.user("Hi")])
        XCTAssertNil(try body(request)["system"])
    }

    func testStreamFlagIsOnlyPresentWhenStreaming() throws {
        XCTAssertNil(try body(MessagesRequest(maxTokens: 100, messages: [.user("x")]))["stream"])
        XCTAssertEqual(
            try body(MessagesRequest(maxTokens: 100, messages: [.user("x")], stream: true))["stream"]?.boolValue,
            true
        )
    }

    func testEffortIsNestedInsideOutputConfig() throws {
        let request = MessagesRequest(maxTokens: 100, messages: [.user("x")], effort: .xhigh)
        let json = try body(request)
        XCTAssertNil(json["effort"], "effort is not a top-level parameter")
        XCTAssertEqual(json["output_config"]?["effort"]?.stringValue, "xhigh")
    }

    func testStructuredOutputSchemaIsAttachedUnderOutputConfigFormat() throws {
        let request = MessagesRequest(
            maxTokens: 100, messages: [.user("x")], outputSchema: Schemas.recallQuestion
        )
        let format = try XCTUnwrap(try body(request)["output_config"]?["format"])
        XCTAssertEqual(format["type"]?.stringValue, "json_schema")
        XCTAssertEqual(format["schema"]?["type"]?.stringValue, "object")
        XCTAssertNotNil(format["schema"]?["properties"]?["distractors"])
    }

    func testOutputConfigIsOmittedWhenNothingToConfigure() throws {
        let request = MessagesRequest(maxTokens: 100, messages: [.user("x")], effort: nil)
        XCTAssertNil(try body(request)["output_config"])
    }

    func testHeadersCarryKeyAndVersion() {
        let headers = MessagesRequest.headers(apiKey: "sk-ant-test")
        XCTAssertEqual(headers["x-api-key"], "sk-ant-test")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(headers["content-type"], "application/json")
    }

    func testEncodedBodyIsDeterministic() throws {
        let request = MessagesRequest(maxTokens: 100, system: "s", messages: [.user("x")])
        XCTAssertEqual(try request.encodedBody(), try request.encodedBody())
    }

    // MARK: - Schema validity

    func testEverySchemaObjectForbidsAdditionalPropertiesAndListsRequired() {
        for (name, schema) in [
            ("suggestions", Schemas.topicSuggestions),
            ("lesson", Schemas.lesson),
            ("chapter", Schemas.chapter),
            ("recall", Schemas.recallQuestion),
        ] {
            assertStrictObject(schema, name: name)
        }
    }

    private func assertStrictObject(_ schema: JSONValue, name: String) {
        guard let object = schema.objectValue else { return }
        if object["type"]?.stringValue == "object" {
            XCTAssertEqual(object["additionalProperties"]?.boolValue, false, "\(name): additionalProperties must be false")
            let properties = object["properties"]?.objectValue ?? [:]
            let required = Set((object["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            XCTAssertEqual(required, Set(properties.keys), "\(name): every property must be required")
            for (key, value) in properties {
                assertStrictObject(value, name: "\(name).\(key)")
            }
        }
        if let items = object["items"] {
            assertStrictObject(items, name: "\(name)[]")
        }
    }

    func testLessonSchemaCoversEveryLessonField() {
        let properties = Schemas.lesson["properties"]?.objectValue ?? [:]
        for field in ["title", "subtitle", "domainTag", "bodyMarkdown", "surprisingClaim", "deeperAngles"] {
            XCTAssertNotNil(properties[field], "lesson schema missing \(field)")
        }
    }

    func testSuggestionSchemaItemsCoverEveryField() {
        let items = Schemas.topicSuggestions["properties"]?["suggestions"]?["items"]
        let properties = items?["properties"]?.objectValue ?? [:]
        for field in ["title", "hook", "domainTag", "isWildcard"] {
            XCTAssertNotNil(properties[field], "suggestion schema missing \(field)")
        }
    }

    /// A schema that round-trips is a schema the API will accept.
    func testSchemasSurviveJSONRoundTrip() throws {
        for schema in [Schemas.topicSuggestions, Schemas.lesson, Schemas.chapter, Schemas.recallQuestion] {
            let data = try JSONEncoder().encode(schema)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), schema)
        }
    }

    // MARK: - Response decoding

    func testDecodesTextResponseAndUsage() throws {
        let json = Data("""
        {"id":"msg_1","model":"claude-opus-5","stop_reason":"end_turn",
         "content":[{"type":"text","text":"{\\"a\\":1}"}],
         "usage":{"input_tokens":120,"output_tokens":900,
                  "cache_creation_input_tokens":10,"cache_read_input_tokens":5}}
        """.utf8)
        let response = try MessagesResponse.decode(json)
        XCTAssertEqual(response.model, "claude-opus-5")
        XCTAssertEqual(response.stopReason, "end_turn")
        XCTAssertEqual(response.text, "{\"a\":1}")
        XCTAssertEqual(response.usage.inputTokens, 120)
        XCTAssertEqual(response.usage.outputTokens, 900)
        XCTAssertEqual(response.usage.cacheCreationInputTokens, 10)
        XCTAssertEqual(response.usage.cacheReadInputTokens, 5)
        XCTAssertFalse(response.isRefusal)
    }

    func testConcatenatesTextAcrossMultipleBlocks() throws {
        let json = Data("""
        {"content":[{"type":"text","text":"{\\"title\\":"},
                    {"type":"thinking","thinking":"ignored"},
                    {"type":"text","text":"\\"x\\"}"}]}
        """.utf8)
        let response = try MessagesResponse.decode(json)
        XCTAssertEqual(response.text, "{\"title\":\"x\"}")
    }

    func testDecodesRefusalWithCategory() throws {
        let json = Data("""
        {"model":"claude-opus-5","stop_reason":"refusal","content":[],
         "stop_details":{"type":"refusal","category":"cyber","explanation":"declined"}}
        """.utf8)
        let response = try MessagesResponse.decode(json)
        XCTAssertTrue(response.isRefusal)
        XCTAssertEqual(response.refusalCategory, "cyber")
        XCTAssertEqual(response.refusalExplanation, "declined")
    }

    func testRefusalThrowsWhenDecodingPayload() throws {
        let json = Data("""
        {"stop_reason":"refusal","content":[],
         "stop_details":{"category":"bio","explanation":"no"}}
        """.utf8)
        let response = try MessagesResponse.decode(json)
        XCTAssertThrowsError(try response.decodePayload(Lesson.self)) { error in
            XCTAssertEqual(
                error as? LessonProviderError,
                .refused(category: "bio", explanation: "no")
            )
        }
    }

    func testDecodesStructuredPayload() throws {
        let payload = #"{"suggestions":[{"title":"A","hook":"h","domainTag":"D","isWildcard":true}]}"#
        let json = Data("{\"content\":[{\"type\":\"text\",\"text\":\(JSONEncodedString(payload))}]}".utf8)
        let response = try MessagesResponse.decode(json)
        let decoded = try response.decodePayload(TopicSuggestionsResponse.self)
        XCTAssertEqual(decoded.suggestions.count, 1)
        XCTAssertTrue(decoded.suggestions[0].isWildcard)
    }

    func testAPIErrorEnvelopeThrows() {
        let json = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8)
        XCTAssertThrowsError(try MessagesResponse.decode(json)) { error in
            XCTAssertEqual(error as? LessonProviderError, .decoding("slow down"))
        }
    }

    func testNonJSONBodyThrowsDecodingError() {
        XCTAssertThrowsError(try MessagesResponse.decode(Data("<html>502</html>".utf8))) { error in
            guard case .decoding = error as? LessonProviderError else {
                return XCTFail("expected a decoding error, got \(error)")
            }
        }
    }

    func testEmptyTextThrowsRatherThanReturningAnEmptyLesson() throws {
        let response = try MessagesResponse.decode(Data(#"{"content":[]}"#.utf8))
        XCTAssertThrowsError(try response.decodePayload(Lesson.self))
    }

    func testMissingUsageDefaultsToZero() throws {
        let response = try MessagesResponse.decode(Data(#"{"content":[{"type":"text","text":"hi"}]}"#.utf8))
        XCTAssertEqual(response.usage, TokenUsage())
    }

    // MARK: - Error classification

    func testRetryClassification() {
        XCTAssertTrue(LessonProviderError.network("timeout").isRetryable)
        XCTAssertTrue(LessonProviderError.malformedStream("truncated").isRetryable)
        XCTAssertTrue(LessonProviderError.httpStatus(code: 429, message: "").isRetryable)
        XCTAssertTrue(LessonProviderError.httpStatus(code: 529, message: "").isRetryable)
        XCTAssertTrue(LessonProviderError.httpStatus(code: 500, message: "").isRetryable)

        XCTAssertFalse(LessonProviderError.httpStatus(code: 400, message: "").isRetryable)
        XCTAssertFalse(LessonProviderError.httpStatus(code: 401, message: "").isRetryable)
        XCTAssertFalse(LessonProviderError.missingAPIKey.isRetryable)
        XCTAssertFalse(LessonProviderError.decoding("bad").isRetryable)
        XCTAssertFalse(LessonProviderError.refused(category: nil, explanation: nil).isRetryable)
        XCTAssertFalse(LessonProviderError.cancelled.isRetryable)
    }

    // MARK: - JSONValue

    func testJSONValueRoundTripsEveryCase() throws {
        let value = JSONValue.object([
            "null": .null,
            "bool": .bool(true),
            "int": .int(7),
            "double": .double(1.5),
            "string": .string("s"),
            "array": .array([.int(1), .string("two")]),
            "nested": .object(["k": .bool(false)]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testJSONValueAccessors() {
        let value = JSONValue.object(["a": .string("x"), "n": .int(2), "arr": .array([.bool(true)])])
        XCTAssertEqual(value["a"]?.stringValue, "x")
        XCTAssertEqual(value["n"]?.intValue, 2)
        XCTAssertEqual(value["arr"]?.arrayValue?.count, 1)
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["a"]?.intValue)
    }

    // MARK: Helper

    /// JSON-encodes a string so it can be embedded inside a JSON literal.
    private func JSONEncodedString(_ raw: String) -> String {
        let data = try? JSONEncoder().encode(raw)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
