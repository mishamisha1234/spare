import Foundation
@testable import SpareCore

/// Recorded Anthropic wire responses, and a transport that replays them.
///
/// CI never holds an API key and never makes a real call: no spend, no
/// flakiness, no secret to leak. Everything the provider does — streaming,
/// retry, refusal handling, usage accounting — is driven from these.
/// Real-API verification is a manual step on a Mac.
enum HTTPFixtures {

    // MARK: - SSE construction

    /// One SSE record. Kept as explicit `\n\n` concatenation rather than a
    /// multiline literal so the record separator is unambiguous.
    static func event(_ name: String, _ data: String) -> String {
        "event: \(name)\ndata: \(data)\n\n"
    }

    static func jsonEncoded(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    static func messageStart(inputTokens: Int = 1_200, cacheRead: Int = 0) -> String {
        event("message_start", """
        {"type":"message_start","message":{"model":"claude-opus-5","usage":{"input_tokens":\(inputTokens),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":\(cacheRead)}}}
        """)
    }

    static func textDelta(_ text: String) -> String {
        event("content_block_delta", """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\(jsonEncoded(text))}}
        """)
    }

    static func messageDelta(stopReason: String = "end_turn", outputTokens: Int = 900) -> String {
        event("message_delta", """
        {"type":"message_delta","delta":{"stop_reason":"\(stopReason)"},"usage":{"output_tokens":\(outputTokens)}}
        """)
    }

    static let messageStop = event("message_stop", #"{"type":"message_stop"}"#)

    /// A complete, well-formed stream carrying `json`, split into several
    /// deltas so the streaming extractor is genuinely exercised.
    static func stream(
        json: String,
        chunks: Int = 6,
        inputTokens: Int = 1_200,
        outputTokens: Int = 900,
        cacheRead: Int = 0
    ) -> String {
        var output = messageStart(inputTokens: inputTokens, cacheRead: cacheRead)
        output += event("content_block_start", """
        {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        """)
        for piece in split(json, into: chunks) {
            output += textDelta(piece)
        }
        output += event("content_block_stop", #"{"type":"content_block_stop","index":0}"#)
        output += messageDelta(outputTokens: outputTokens)
        output += messageStop
        return output
    }

    /// Cut off mid-body: no `message_stop`, and the JSON never closes.
    static func truncatedStream(json: String) -> String {
        var output = messageStart()
        let pieces = split(json, into: 4)
        for piece in pieces.prefix(2) {
            output += textDelta(piece)
        }
        return output
    }

    static func refusalStream() -> String {
        messageStart() + messageDelta(stopReason: "refusal", outputTokens: 0) + messageStop
    }

    static func errorStream(type: String, message: String) -> String {
        messageStart() + event("error", """
        {"type":"error","error":{"type":"\(type)","message":"\(message)"}}
        """)
    }

    static func split(_ text: String, into pieces: Int) -> [String] {
        guard pieces > 1, text.count > pieces else { return [text] }
        let size = max(1, text.count / pieces)
        var result: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end]))
            index = end
        }
        return result
    }

    // MARK: - Non-streaming bodies

    static func messageBody(
        json: String,
        inputTokens: Int = 800,
        outputTokens: Int = 300,
        stopReason: String = "end_turn"
    ) -> String {
        """
        {"id":"msg_fixture","type":"message","model":"claude-opus-5",
         "stop_reason":"\(stopReason)",
         "content":[{"type":"text","text":\(jsonEncoded(json))}],
         "usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),
                  "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """
    }

    static let rateLimitBody = """
    {"type":"error","error":{"type":"rate_limit_error","message":"Number of requests has exceeded your rate limit"}}
    """

    static let overloadedBody = """
    {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    """

    // MARK: - Payloads

    static func lessonJSON(
        title: String = "Why bridges hum",
        body: String = "On June 10, 2000, the Millennium Bridge opened across the Thames. It swayed."
    ) -> String {
        """
        {"title":\(jsonEncoded(title)),"subtitle":"A 10-minute explainer","domainTag":"Engineering","bodyMarkdown":\(jsonEncoded(body)),"surprisingClaim":"Pedestrians synchronised with the sway.","deeperAngles":["Resonance","Dampers","Over-damping"]}
        """
    }

    static func chapterJSON(
        heading: String = "The day it happened",
        body: String = "On June 10, 2000, the bridge opened.\n\n*Where do you cross something engineered to move?*"
    ) -> String {
        """
        {"heading":\(jsonEncoded(heading)),"bodyMarkdown":\(jsonEncoded(body))}
        """
    }

    static func outlineJSON(chapterCount: Int = TimeWindow.thirty.format.chapterCount) -> String {
        let headings = (1...chapterCount)
            .map { jsonEncoded("Chapter theme \($0)") }
            .joined(separator: ",")
        return """
        {"title":"How planes got safe","subtitle":"A 30-minute course","domainTag":"Engineering","surprisingClaim":"Every rule was written after a crash.","deeperAngles":["Context","Mechanism","Counterargument"],"chapterHeadings":[\(headings)]}
        """
    }

    static let suggestionsJSON = """
    {"suggestions":[
      {"title":"Why bridges hum","hook":"Wind makes steel sing on purpose.","domainTag":"Engineering","isWildcard":false},
      {"title":"The florin that priced Europe","hook":"One coin set rates for centuries.","domainTag":"History","isWildcard":false},
      {"title":"Why knees predict rain","hook":"Pressure moves joint fluid enough to feel.","domainTag":"Biology","isWildcard":false},
      {"title":"Surge pricing before computers","hook":"Fish markets got there first.","domainTag":"Economics","isWildcard":false},
      {"title":"Why choirs drift sharp","hook":"Group pitch rises, and physics insists.","domainTag":"Music","isWildcard":true}
    ]}
    """

    static let recallJSON = """
    {"question":"What drove the sway?","answer":"Pedestrians synchronising with the deck","distractors":["Wind alone","A construction fault","Traffic on a nearby road"],"explanation":"Each correction fed the wobble it corrected."}
    """

    static let postLessonTestJSON = """
    {"questions":[
      {"question":"What drove the sway?","answer":"Pedestrians synchronising with the deck","distractors":["Wind alone","A construction fault","Traffic on a nearby road"],"explanation":"Each correction fed the wobble it corrected."},
      {"question":"What is the fix called?","answer":"A tuned mass damper","distractors":["A stiffening truss","A base isolator","A cross-brace"],"explanation":"A weight on a spring that swings out of phase."},
      {"question":"When did the bridge close?","answer":"Two days after opening","distractors":["The day it opened","One week after opening","It never closed"],"explanation":"It closed within two days of the wobble."}
    ]}
    """
}

// MARK: - Replay transport

/// Serves queued fixtures in order and records every request it was given.
final class FixtureTransport: HTTPTransport, @unchecked Sendable {

    enum Step {
        /// Non-streaming response.
        case body(status: Int, text: String)
        /// Streaming response: raw SSE text, delivered in byte chunks.
        case sse(String)
        /// Streaming response that fails partway, e.g. a dropped connection.
        case sseThenError(String, LessonProviderError)
        /// Transport-level failure before any bytes arrive.
        case failure(LessonProviderError)
    }

    private let lock = NSLock()
    private var queue: [Step]
    private var received: [HTTPRequest] = []
    /// Chunk size used when replaying SSE, so multi-byte and mid-record splits
    /// are exercised rather than delivering each record whole.
    private let chunkSize: Int

    init(_ steps: [Step], chunkSize: Int = 24) {
        self.queue = steps
        self.chunkSize = chunkSize
    }

    convenience init(_ step: Step, chunkSize: Int = 24) {
        self.init([step], chunkSize: chunkSize)
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var requestCount: Int { requests.count }

    var remainingSteps: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    private func next(for request: HTTPRequest) -> Step {
        lock.lock()
        defer { lock.unlock() }
        received.append(request)
        guard !queue.isEmpty else {
            return .failure(.network("fixture transport ran out of steps"))
        }
        return queue.removeFirst()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch next(for: request) {
        case .body(let status, let text):
            return HTTPResponse(statusCode: status, body: Data(text.utf8))
        case .failure(let error):
            throw error
        case .sse(let text), .sseThenError(let text, _):
            return HTTPResponse(statusCode: 200, body: Data(text.utf8))
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let step = next(for: request)
        let size = chunkSize
        return AsyncThrowingStream { continuation in
            switch step {
            case .failure(let error):
                continuation.finish(throwing: error)
            case .body(let status, let text):
                if (200..<300).contains(status) {
                    continuation.yield(Data(text.utf8))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: HTTPTransportMapper.providerError(
                        status: status, body: Data(text.utf8)
                    ))
                }
            case .sse(let text):
                for chunk in Self.byteChunks(of: text, size: size) {
                    continuation.yield(chunk)
                }
                continuation.finish()
            case .sseThenError(let text, let error):
                for chunk in Self.byteChunks(of: text, size: size) {
                    continuation.yield(chunk)
                }
                continuation.finish(throwing: error)
            }
        }
    }

    static func byteChunks(of text: String, size: Int) -> [Data] {
        let bytes = Array(text.utf8)
        guard size > 0, bytes.count > size else { return [Data(bytes)] }
        var result: [Data] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + size, bytes.count)
            result.append(Data(bytes[index..<end]))
            index = end
        }
        return result
    }
}
