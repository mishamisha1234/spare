import Foundation

/// Model and endpoint constants. One place to change when moving to a proxy.
public enum AnthropicAPI {
    /// The generation model. Lesson quality is the product, so this is the most
    /// capable generally available model rather than the cheapest.
    public static let model = "claude-opus-5"

    public static let baseURL = "https://api.anthropic.com"
    public static let messagesPath = "/v1/messages"
    public static let versionHeader = "2023-06-01"

    /// Streaming is used for anything long; these ceilings leave room for
    /// thinking plus prose.
    public static func maxTokens(for window: TimeWindow) -> Int {
        switch window {
        case .three: return 8_000
        case .ten: return 16_000
        case .fifteen: return 24_000
        // Per chapter, generated one at a time. Raised from 16,000 after the
        // first 30-minute course to get past the outline came back truncated
        // mid-chapter: `stop_reason` was `max_tokens`.
        //
        // A chapter's prose is only ~1,550 words, which looks like it should fit
        // in far less. Thinking is what does not scale down — it costs roughly
        // the same per call whether the call writes 1,500 words or 3,000, so a
        // smaller prose budget means thinking takes a larger share of the
        // ceiling, not a smaller one. A 15-minute lesson writes nearly twice the
        // words within 24,000 and is fine.
        //
        // Costs nothing to raise: max_tokens is a ceiling, not a reservation.
        // Output is billed on what comes back.
        case .thirty: return 24_000
        }
    }

    public static var messagesURL: URL? {
        URL(string: baseURL + messagesPath)
    }

    /// How long one call may take before it is abandoned.
    ///
    /// Two values rather than one, because the calls are not the same size. A
    /// recall question is a few hundred tokens and hanging for a quarter of an
    /// hour would only ever be a fault; a chapter of a 30-minute course is
    /// 24,000 tokens of thinking and prose and legitimately takes minutes.
    ///
    /// The generation figure is set from a failure rather than a guess. Raising
    /// the 30-minute ceiling from 16,000 stopped the chapters truncating and
    /// started them timing out instead — the same call, given room to finish,
    /// ran past the flat 300 seconds every request used to get. A ceiling that
    /// cuts off a call which is still streaming correctly throws away the whole
    /// chapter, so it wants to be generous: this only ever bounds a call that
    /// has genuinely stopped.
    ///
    /// Worth knowing when reading it: `URLRequest.timeoutInterval` is an idle
    /// timer on Darwin — reset every time bytes arrive — and swift-corelibs on
    /// Linux is stricter, which is where the batch tool runs. The value has to
    /// be big enough to survive the stricter reading, so it is the whole
    /// duration of the longest legitimate call, not the longest legitimate gap.
    public static func timeout(for kind: UsageKind) -> TimeInterval {
        switch kind {
        case .suggestions, .recallQuestion, .postLessonTest, .courseOutline:
            return 180
        case .lessonDraft, .lessonRevision, .chapterDraft, .chapterRevision,
             .goDeeperDraft, .goDeeperRevision:
            return 900
        }
    }
}

/// Effort level for `output_config`.
public enum Effort: String, Sendable, Codable {
    case low, medium, high, xhigh, max
}

/// A Messages API request body, encoded by hand so the shape is explicit and
/// testable without a networking round trip.
public struct MessagesRequest: Sendable, Equatable {
    public var model: String
    public var maxTokens: Int
    public var system: String?
    public var messages: [Message]
    public var stream: Bool
    public var effort: Effort?
    /// JSON schema for structured outputs, when the response must be parseable.
    public var outputSchema: JSONValue?
    /// Cache the system prompt: it is identical across every lesson request.
    public var cacheSystemPrompt: Bool

    public struct Message: Sendable, Equatable {
        public var role: String
        public var text: String

        public init(role: String, text: String) {
            self.role = role
            self.text = text
        }

        public static func user(_ text: String) -> Message { Message(role: "user", text: text) }
    }

    public init(
        model: String = AnthropicAPI.model,
        maxTokens: Int,
        system: String? = nil,
        messages: [Message],
        stream: Bool = false,
        effort: Effort? = .high,
        outputSchema: JSONValue? = nil,
        cacheSystemPrompt: Bool = true
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.stream = stream
        self.effort = effort
        self.outputSchema = outputSchema
        self.cacheSystemPrompt = cacheSystemPrompt
    }

    /// The request as a JSON tree.
    ///
    /// Notes on shape:
    /// - `thinking` is omitted: adaptive thinking is the default on this model.
    /// - `temperature`/`top_p`/`top_k` are omitted: rejected on current models.
    /// - No assistant prefill: rejected on current models. Response shape is
    ///   constrained with `output_config.format` instead.
    public var jsonBody: JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .int(maxTokens),
            "messages": .array(messages.map { message in
                .object([
                    "role": .string(message.role),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(message.text)]),
                    ]),
                ])
            }),
        ]

        if let system {
            var block: [String: JSONValue] = [
                "type": .string("text"),
                "text": .string(system),
            ]
            if cacheSystemPrompt {
                block["cache_control"] = .object(["type": .string("ephemeral")])
            }
            body["system"] = .array([.object(block)])
        }

        if stream {
            body["stream"] = .bool(true)
        }

        var outputConfig: [String: JSONValue] = [:]
        if let effort {
            outputConfig["effort"] = .string(effort.rawValue)
        }
        if let outputSchema {
            outputConfig["format"] = .object([
                "type": .string("json_schema"),
                "schema": outputSchema,
            ])
        }
        if !outputConfig.isEmpty {
            body["output_config"] = .object(outputConfig)
        }

        return .object(body)
    }

    public func encodedBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(jsonBody)
    }

    public static func headers(apiKey: String) -> [String: String] {
        [
            "content-type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": AnthropicAPI.versionHeader,
        ]
    }
}

/// A non-streaming Messages API response, reduced to what the app reads.
public struct MessagesResponse: Sendable, Equatable {
    public var model: String
    public var stopReason: String?
    public var refusalCategory: String?
    public var refusalExplanation: String?
    public var text: String
    public var usage: TokenUsage

    public var isRefusal: Bool { stopReason == "refusal" }

    public init(
        model: String = "",
        stopReason: String? = nil,
        refusalCategory: String? = nil,
        refusalExplanation: String? = nil,
        text: String = "",
        usage: TokenUsage = TokenUsage()
    ) {
        self.model = model
        self.stopReason = stopReason
        self.refusalCategory = refusalCategory
        self.refusalExplanation = refusalExplanation
        self.text = text
        self.usage = usage
    }

    /// Parses a response body. Concatenates every `text` block, so a response
    /// split across blocks still yields complete JSON.
    public static func decode(_ data: Data) throws -> MessagesResponse {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw LessonProviderError.decoding("response was not JSON: \(error)")
        }

        if root["type"]?.stringValue == "error" {
            let message = root["error"]?["message"]?.stringValue ?? "unknown error"
            throw LessonProviderError.decoding(message)
        }

        let blocks = root["content"]?.arrayValue ?? []
        let text = blocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()

        let usageNode = root["usage"]
        let usage = TokenUsage(
            inputTokens: usageNode?["input_tokens"]?.intValue ?? 0,
            outputTokens: usageNode?["output_tokens"]?.intValue ?? 0,
            cacheCreationInputTokens: usageNode?["cache_creation_input_tokens"]?.intValue ?? 0,
            cacheReadInputTokens: usageNode?["cache_read_input_tokens"]?.intValue ?? 0
        )

        return MessagesResponse(
            model: root["model"]?.stringValue ?? "",
            stopReason: root["stop_reason"]?.stringValue,
            refusalCategory: root["stop_details"]?["category"]?.stringValue,
            refusalExplanation: root["stop_details"]?["explanation"]?.stringValue,
            text: text,
            usage: usage
        )
    }

    /// Decodes the structured-output payload, checking for a refusal first.
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        if isRefusal {
            throw LessonProviderError.refused(
                category: refusalCategory,
                explanation: refusalExplanation
            )
        }
        guard let data = text.data(using: .utf8), !text.isEmpty else {
            throw LessonProviderError.decoding("empty response body")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LessonProviderError.decoding("\(type) did not decode: \(error)")
        }
    }
}
