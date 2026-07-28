import Foundation

/// One Server-Sent Event: the `event:` name and the joined `data:` payload.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental SSE parser.
///
/// Buffers **bytes**, not characters: HTTP chunk boundaries fall wherever the
/// network puts them, including mid-UTF-8-sequence, so decoding per chunk would
/// corrupt multi-byte characters. Only complete records (terminated by a blank
/// line) are decoded.
public struct SSEParser: Sendable {

    private var buffer: [UInt8] = []

    public init() {}

    /// Feed raw bytes; returns whatever complete events they completed.
    public mutating func consume<Bytes: Sequence>(_ bytes: Bytes) -> [SSEEvent]
    where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        return drainCompleteRecords()
    }

    public mutating func consume(_ data: Data) -> [SSEEvent] {
        consume(Array(data))
    }

    /// Flush a trailing record that arrived without a final blank line, which
    /// some servers omit at end of stream.
    public mutating func finish() -> [SSEEvent] {
        guard !buffer.isEmpty else { return [] }
        let remainder = buffer
        buffer.removeAll(keepingCapacity: false)
        guard let text = String(bytes: remainder, encoding: .utf8) else { return [] }
        return Self.parseRecord(text).map { [$0] } ?? []
    }

    private mutating func drainCompleteRecords() -> [SSEEvent] {
        var events: [SSEEvent] = []
        while let boundary = Self.nextBoundary(in: buffer) {
            let recordBytes = Array(buffer[..<boundary.start])
            buffer.removeFirst(boundary.end)
            guard let text = String(bytes: recordBytes, encoding: .utf8) else { continue }
            if let event = Self.parseRecord(text) {
                events.append(event)
            }
        }
        return events
    }

    /// Finds the first record separator. SSE allows LF LF, CRLF CRLF, and CR CR.
    /// Returns the index where the record ends and the index where the next
    /// record starts.
    static func nextBoundary(in bytes: [UInt8]) -> (start: Int, end: Int)? {
        let lf: UInt8 = 0x0A
        let cr: UInt8 = 0x0D
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == lf {
                // \n\n
                if index + 1 < bytes.count, bytes[index + 1] == lf {
                    return (index, index + 2)
                }
                // \n\r\n
                if index + 2 < bytes.count, bytes[index + 1] == cr, bytes[index + 2] == lf {
                    return (index, index + 3)
                }
            } else if byte == cr {
                // \r\n\r\n
                if index + 3 < bytes.count,
                   bytes[index + 1] == lf, bytes[index + 2] == cr, bytes[index + 3] == lf {
                    return (index, index + 4)
                }
                // \r\r
                if index + 1 < bytes.count, bytes[index + 1] == cr {
                    return (index, index + 2)
                }
            }
            index += 1
        }
        return nil
    }

    static func parseRecord(_ record: String) -> SSEEvent? {
        var eventName: String?
        var dataLines: [String] = []

        for rawLine in record.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            // Comments/heartbeats.
            if line.hasPrefix(":") { continue }

            guard let colon = line.firstIndex(of: ":") else {
                // A field name with no value; nothing we act on.
                continue
            }
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "event": eventName = value
            case "data": dataLines.append(value)
            default: break // id, retry — unused here
            }
        }

        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

// MARK: - Anthropic stream event decoding

/// The subset of Messages API streaming events this app acts on.
public enum AnthropicStreamEvent: Sendable, Equatable {
    case messageStart(model: String)
    case textDelta(String)
    /// Structured outputs and tool inputs arrive as partial JSON.
    case inputJSONDelta(String)
    case contentBlockStart(type: String)
    case contentBlockStop
    case messageDelta(stopReason: String?, outputTokens: Int?)
    case messageStop
    case usage(TokenUsage)
    case ping
    case error(type: String, message: String)
    /// Any event type we don't model.
    case other(String)
}

public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        )
    }
}

public enum AnthropicStreamDecoder {

    /// Decodes one SSE payload into a modelled event. Returns nil for
    /// `[DONE]`-style sentinels and unparseable payloads.
    public static func decode(_ sse: SSEEvent) -> AnthropicStreamEvent? {
        let payload = sse.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = root["type"]?.stringValue else { return nil }

        switch type {
        case "message_start":
            let model = root["message"]?["model"]?.stringValue ?? ""
            return .messageStart(model: model)

        case "content_block_start":
            let blockType = root["content_block"]?["type"]?.stringValue ?? "unknown"
            return .contentBlockStart(type: blockType)

        case "content_block_delta":
            guard let delta = root["delta"], let deltaType = delta["type"]?.stringValue else {
                return .other(type)
            }
            switch deltaType {
            case "text_delta":
                return .textDelta(delta["text"]?.stringValue ?? "")
            case "input_json_delta":
                return .inputJSONDelta(delta["partial_json"]?.stringValue ?? "")
            case "thinking_delta":
                return .other("thinking_delta")
            default:
                return .other(deltaType)
            }

        case "content_block_stop":
            return .contentBlockStop

        case "message_delta":
            let stopReason = root["delta"]?["stop_reason"]?.stringValue
            let outputTokens = root["usage"]?["output_tokens"]?.intValue
            return .messageDelta(stopReason: stopReason, outputTokens: outputTokens)

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            let errorType = root["error"]?["type"]?.stringValue ?? "unknown"
            let message = root["error"]?["message"]?.stringValue ?? ""
            return .error(type: errorType, message: message)

        default:
            return .other(type)
        }
    }

    /// Usage from a `message_start` payload, which carries input-token counts.
    public static func usage(from sse: SSEEvent) -> TokenUsage? {
        guard let data = sse.data.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let usage = root["message"]?["usage"] ?? root["usage"] else { return nil }
        return TokenUsage(
            inputTokens: usage["input_tokens"]?.intValue ?? 0,
            outputTokens: usage["output_tokens"]?.intValue ?? 0,
            cacheCreationInputTokens: usage["cache_creation_input_tokens"]?.intValue ?? 0,
            cacheReadInputTokens: usage["cache_read_input_tokens"]?.intValue ?? 0
        )
    }
}
