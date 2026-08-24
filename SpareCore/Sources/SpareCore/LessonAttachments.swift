import Foundation

/// The artifacts that travel with a lesson rather than with a reader.
///
/// A lesson is written once and read by many people. Its recall question and
/// its test are properties of the lesson, so they are generated once, by
/// whichever device generated the lesson, and stored beside it in the pool.
///
/// This is a cost cliff, not a preference. A 30-minute course read by two
/// hundred premium users, at roughly $0.20 of test generation each, is $40 of
/// tests on a lesson that cost $1.40 to write. There is no per-reader test
/// generation anywhere, at any tier.
public struct LessonAttachments: Codable, Sendable, Equatable {
    /// Tomorrow's question. Free for every reader, so both pools carry one,
    /// written by the same model that wrote the lesson — a question from a
    /// stronger model than the one that wrote the lesson can probe something
    /// the lesson never quite establishes, which is fair on the subject and
    /// unfair on the page.
    public var recall: RecallQuestion
    /// The immediate test. Empty in the free pool, which has none: Sonnet is
    /// never asked to write one.
    public var test: [RecallQuestion]

    public init(recall: RecallQuestion, test: [RecallQuestion] = []) {
        self.recall = recall
        self.test = test
    }

    /// A missing `test` decodes as none rather than as a failure. The free
    /// pool has no test, and an absent key is a perfectly good way to say so —
    /// throwing there would turn "no test" into "no recall question either".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.recall = try container.decode(RecallQuestion.self, forKey: .recall)
        self.test = try container.decodeIfPresent([RecallQuestion].self, forKey: .test) ?? []
    }

    public var hasTest: Bool { !test.isEmpty }
}

/// Where a lesson's attachments are read from and written to.
///
/// Separate from `LessonProvider` because it is not a generation surface —
/// nothing here ever calls a model. Keeping it apart is what makes "reading
/// attachments cannot cost money" a property of the type rather than a rule
/// somebody has to remember.
public protocol AttachmentStore: Sendable {
    /// What is already attached, or nil if nothing is yet.
    ///
    /// Nil is a real answer and not an error: the reader may have arrived
    /// between a lesson being cached and its attachments being uploaded. The
    /// caller decides what to do, and for a test the answer is to show
    /// nothing — never to generate one.
    func attachments(for lesson: LessonIdentity) async throws -> LessonAttachments?

    /// Uploads what this device just generated. Accepted only from the device
    /// that generated the lesson, and only in the shape the length calls for.
    func attach(_ attachments: LessonAttachments, for lesson: LessonIdentity) async throws
}

/// Enough to name a lesson in the pool. Mirrors the proxy's cache key.
public struct LessonIdentity: Sendable, Equatable, Codable {
    public var window: TimeWindow
    public var topic: String
    /// The interest category the lesson was generated under. Premium pool
    /// only; the free pool ignores it.
    public var interest: String

    public init(window: TimeWindow, topic: String, interest: String) {
        self.window = window
        self.topic = topic
        self.interest = interest
    }

    public var format: LessonFormat { window.format }
}

/// The offline and dev answer: nothing is ever attached, so everything is
/// generated locally.
///
/// Correct rather than a stub. `MockProvider` and the direct-to-Anthropic route
/// have no shared pool to attach to — there is no other reader — so generating
/// per reader is not a cost cliff there, it is the only thing that makes sense.
public struct NoAttachmentStore: AttachmentStore {
    public init() {}

    public func attachments(for lesson: LessonIdentity) async throws -> LessonAttachments? { nil }
    public func attach(_ attachments: LessonAttachments, for lesson: LessonIdentity) async throws {}
}

/// Reads and writes attachments through the Spare proxy.
public struct ProxyAttachmentStore: AttachmentStore {
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let deviceID: String
    private let receipt: @Sendable () async -> String?

    public init(
        transport: any HTTPTransport,
        baseURL: URL,
        deviceID: String,
        receipt: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.receipt = receipt
    }

    public func attachments(for lesson: LessonIdentity) async throws -> LessonAttachments? {
        let response = try await send(path: "/v1/attachments", extra: [:], for: lesson)
        // 404 is "not yet", which is a normal state and not a failure. Anything
        // else is a real error and is thrown, because a reader silently losing
        // tomorrow's question is the kind of quiet breakage that never gets
        // reported.
        if response.statusCode == 404 { return nil }
        guard response.isSuccess else {
            throw HTTPTransportMapper.providerError(
                status: response.statusCode, body: response.body
            )
        }
        return try JSONDecoder().decode(LessonAttachments.self, from: response.body)
    }

    public func attach(_ attachments: LessonAttachments, for lesson: LessonIdentity) async throws {
        let encoded = try JSONEncoder().encode(attachments)
        let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let response = try await send(
            path: "/v1/attach", extra: ["attachments": value], for: lesson
        )
        guard response.isSuccess else {
            throw HTTPTransportMapper.providerError(
                status: response.statusCode, body: response.body
            )
        }
    }

    private func send(
        path: String,
        extra: [String: JSONValue],
        for lesson: LessonIdentity
    ) async throws -> HTTPResponse {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw LessonProviderError.network("invalid proxy URL")
        }
        var envelope: [String: JSONValue] = [
            "window": .string(lesson.window.rawValue),
            "format": .string(lesson.format.rawValue),
            "topic": .string(lesson.topic),
            "interest": .string(lesson.interest),
        ]
        for (key, value) in extra { envelope[key] = value }
        if let receipt = await receipt(), !receipt.isEmpty {
            envelope["receipt"] = .string(receipt)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try await transport.send(HTTPRequest(
            url: url,
            headers: ["content-type": "application/json", "x-spare-device": deviceID],
            body: try encoder.encode(JSONValue.object(envelope)),
            // Neither call reaches a model, so neither needs a model's patience.
            timeout: 30
        ))
    }
}
