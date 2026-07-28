import XCTest
@testable import SpareCore

final class SSEParserTests: XCTestCase {

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    // MARK: - Framing

    func testParsesSingleEvent() {
        var parser = SSEParser()
        let events = parser.consume(bytes("event: ping\ndata: {}\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: "ping", data: "{}")])
    }

    func testParsesMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.consume(bytes("data: one\n\ndata: two\n\ndata: three\n\n"))
        XCTAssertEqual(events.map(\.data), ["one", "two", "three"])
    }

    func testWaitsForCompleteRecord() {
        var parser = SSEParser()
        XCTAssertTrue(parser.consume(bytes("data: partial")).isEmpty)
        XCTAssertTrue(parser.consume(bytes(" more")).isEmpty)
        let events = parser.consume(bytes("\n\n"))
        XCTAssertEqual(events.map(\.data), ["partial more"])
    }

    func testHandlesEventSplitAcrossManyChunks() {
        var parser = SSEParser()
        var collected: [SSEEvent] = []
        for fragment in ["ev", "ent: message_st", "art\nda", "ta: {\"a\":1}", "\n", "\n"] {
            collected += parser.consume(bytes(fragment))
        }
        XCTAssertEqual(collected, [SSEEvent(event: "message_start", data: "{\"a\":1}")])
    }

    func testHandlesCRLFLineEndings() {
        var parser = SSEParser()
        let events = parser.consume(bytes("event: ping\r\ndata: {}\r\n\r\n"))
        XCTAssertEqual(events, [SSEEvent(event: "ping", data: "{}")])
    }

    func testJoinsMultipleDataLinesWithNewline() {
        var parser = SSEParser()
        let events = parser.consume(bytes("data: line one\ndata: line two\n\n"))
        XCTAssertEqual(events.map(\.data), ["line one\nline two"])
    }

    func testIgnoresCommentHeartbeats() {
        var parser = SSEParser()
        let events = parser.consume(bytes(": heartbeat\n\ndata: real\n\n"))
        XCTAssertEqual(events.map(\.data), ["real"])
    }

    func testIgnoresIdAndRetryFields() {
        var parser = SSEParser()
        let events = parser.consume(bytes("id: 42\nretry: 1000\ndata: payload\n\n"))
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "payload")])
    }

    func testRecordWithNoDataIsDropped() {
        var parser = SSEParser()
        XCTAssertTrue(parser.consume(bytes("event: ping\n\n")).isEmpty)
    }

    func testValueWithoutLeadingSpaceIsAccepted() {
        var parser = SSEParser()
        let events = parser.consume(bytes("data:tight\n\n"))
        XCTAssertEqual(events.map(\.data), ["tight"])
    }

    func testDataContainingColonsSurvives() {
        var parser = SSEParser()
        let events = parser.consume(bytes("data: {\"url\":\"https://example.com:8443/x\"}\n\n"))
        XCTAssertEqual(events.map(\.data), ["{\"url\":\"https://example.com:8443/x\"}"])
    }

    func testFinishFlushesTrailingRecordWithoutBlankLine() {
        var parser = SSEParser()
        XCTAssertTrue(parser.consume(bytes("data: last")).isEmpty)
        XCTAssertEqual(parser.finish().map(\.data), ["last"])
    }

    func testFinishOnEmptyBufferYieldsNothing() {
        var parser = SSEParser()
        _ = parser.consume(bytes("data: x\n\n"))
        XCTAssertTrue(parser.finish().isEmpty)
    }

    /// The reason the parser buffers bytes rather than characters.
    func testMultiByteCharacterSplitAcrossChunksIsNotCorrupted() {
        var parser = SSEParser()
        let payload = Array("data: em—dash and é\n\n".utf8)
        // Split mid-way through the em dash's three UTF-8 bytes.
        let firstHalf = Array(payload[0..<10])
        let secondHalf = Array(payload[10...])
        var collected = parser.consume(firstHalf)
        collected += parser.consume(secondHalf)
        XCTAssertEqual(collected.map(\.data), ["em—dash and é"])
    }

    func testByteAtATimeDeliveryStillParses() {
        var parser = SSEParser()
        var collected: [SSEEvent] = []
        for byte in bytes("data: {\"type\":\"ping\"}\n\n") {
            collected += parser.consume([byte])
        }
        XCTAssertEqual(collected.map(\.data), ["{\"type\":\"ping\"}"])
    }

    // MARK: - Anthropic event decoding

    func testDecodesTextDelta() {
        let sse = SSEEvent(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        )
        XCTAssertEqual(AnthropicStreamDecoder.decode(sse), .textDelta("Hello"))
    }

    func testDecodesInputJSONDelta() {
        let sse = SSEEvent(
            event: "content_block_delta",
            data: #"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"tit"}}"#
        )
        XCTAssertEqual(AnthropicStreamDecoder.decode(sse), .inputJSONDelta("{\"tit"))
    }

    func testDecodesMessageStartWithModel() {
        let sse = SSEEvent(
            event: "message_start",
            data: #"{"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":42}}}"#
        )
        XCTAssertEqual(AnthropicStreamDecoder.decode(sse), .messageStart(model: "claude-opus-5"))
        XCTAssertEqual(AnthropicStreamDecoder.usage(from: sse)?.inputTokens, 42)
    }

    func testDecodesMessageDeltaStopReasonAndTokens() {
        let sse = SSEEvent(
            event: "message_delta",
            data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":180}}"#
        )
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(sse),
            .messageDelta(stopReason: "end_turn", outputTokens: 180)
        )
    }

    func testDecodesRefusalStopReason() {
        let sse = SSEEvent(
            event: "message_delta",
            data: #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#
        )
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(sse),
            .messageDelta(stopReason: "refusal", outputTokens: 0)
        )
    }

    func testDecodesErrorEvent() {
        let sse = SSEEvent(
            event: "error",
            data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        )
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(sse),
            .error(type: "overloaded_error", message: "Overloaded")
        )
    }

    func testDecodesLifecycleEvents() {
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(SSEEvent(data: #"{"type":"content_block_stop","index":0}"#)),
            .contentBlockStop
        )
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(SSEEvent(data: #"{"type":"message_stop"}"#)),
            .messageStop
        )
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(SSEEvent(data: #"{"type":"ping"}"#)),
            .ping
        )
        XCTAssertEqual(
            AnthropicStreamDecoder.decode(SSEEvent(data: #"{"type":"content_block_start","content_block":{"type":"text"}}"#)),
            .contentBlockStart(type: "text")
        )
    }

    func testThinkingDeltaIsNotTreatedAsProse() {
        let sse = SSEEvent(
            data: #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#
        )
        XCTAssertEqual(AnthropicStreamDecoder.decode(sse), .other("thinking_delta"))
    }

    func testUnknownEventTypeBecomesOther() {
        let sse = SSEEvent(data: #"{"type":"some_future_event"}"#)
        XCTAssertEqual(AnthropicStreamDecoder.decode(sse), .other("some_future_event"))
    }

    func testMalformedAndSentinelPayloadsReturnNil() {
        XCTAssertNil(AnthropicStreamDecoder.decode(SSEEvent(data: "not json")))
        XCTAssertNil(AnthropicStreamDecoder.decode(SSEEvent(data: "[DONE]")))
        XCTAssertNil(AnthropicStreamDecoder.decode(SSEEvent(data: "")))
        XCTAssertNil(AnthropicStreamDecoder.decode(SSEEvent(data: #"{"no_type":true}"#)))
    }

    // MARK: - Realistic stream

    func testEndToEndStreamReassemblesText() {
        let raw = """
        event: message_start
        data: {"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":10}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type":"ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"On June 10"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", 2000."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        var parser = SSEParser()
        var text = ""
        var stopReason: String?

        for event in parser.consume(bytes(raw)) {
            switch AnthropicStreamDecoder.decode(event) {
            case .textDelta(let delta): text += delta
            case .messageDelta(let reason, _): stopReason = reason
            default: break
            }
        }

        XCTAssertEqual(text, "On June 10, 2000.")
        XCTAssertEqual(stopReason, "end_turn")
    }

    func testTokenUsageAddition() {
        let first = TokenUsage(inputTokens: 10, outputTokens: 20, cacheCreationInputTokens: 5, cacheReadInputTokens: 1)
        let second = TokenUsage(inputTokens: 1, outputTokens: 2, cacheCreationInputTokens: 3, cacheReadInputTokens: 4)
        let sum = first + second
        XCTAssertEqual(sum.inputTokens, 11)
        XCTAssertEqual(sum.outputTokens, 22)
        XCTAssertEqual(sum.cacheCreationInputTokens, 8)
        XCTAssertEqual(sum.cacheReadInputTokens, 5)
    }
}
