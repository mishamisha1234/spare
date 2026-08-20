import Foundation

/// Facts about a call that the destination needs but the prompt doesn't carry.
///
/// The proxy meters and caches, and it can only do either from structured
/// facts: `window` decides whether a length is free-tier legal, `format`
/// decides whether the call counts against the monthly course cap, and `topic`
/// is what the lesson cache keys on. None of it is derivable from the request
/// body without parsing prompts, which is exactly the coupling to avoid.
///
/// The direct route ignores all three. It is carried anyway rather than being
/// assembled only on the proxy path, because a context threaded through one
/// path and skipped on the other drifts the moment a call site is added.
public struct CallContext: Sendable, Equatable {
    public var window: TimeWindow
    public var format: LessonFormat
    /// The lesson's subject, as the reader chose it. Empty where there isn't
    /// one (suggestions), which the proxy reads as "not cacheable".
    public var topic: String

    public init(window: TimeWindow, format: LessonFormat, topic: String = "") {
        self.window = window
        self.format = format
        self.topic = topic
    }

    /// For calls with no lesson of their own. `window` still matters for the
    /// prompt's word budget, so it is not defaulted away.
    public static func plain(window: TimeWindow) -> CallContext {
        CallContext(window: window, format: window.format, topic: "")
    }

    /// For calls about an already-written lesson: recall questions and tests.
    ///
    /// A `Lesson` doesn't record the window it was generated for, so it is
    /// recovered from the body's length. These endpoints are unmetered, so the
    /// value costs nothing if it lands one step off — but sending a fixed
    /// placeholder would be a lie waiting to be depended on.
    public static func about(_ lesson: Lesson) -> CallContext {
        let window = TimeWindow.closest(toMinutes: ReadingTime.minutes(forWordCount: lesson.wordCount))
        return CallContext(window: window, format: window.format, topic: lesson.title)
    }
}

/// Where a generation request is sent, and how it is addressed.
///
/// The two-pass pipeline, retry behaviour, quality checks, and lazy chapter
/// generation are identical whether the request goes to Anthropic or to the
/// Spare proxy. Only the URL, the headers, and the body envelope differ — so
/// that is all this abstracts. Anything more would have produced two pipelines
/// that drift.
public protocol ProviderRoute: Sendable {
    /// Builds the HTTP request. Async because a route may need to fetch a
    /// credential — a Keychain read, or a StoreKit transaction — before it can
    /// address the call.
    func httpRequest(
        for request: MessagesRequest,
        kind: UsageKind,
        context: CallContext
    ) async throws -> HTTPRequest
}

// MARK: - Direct

/// Device → Anthropic, with the user's own key.
///
/// Dev builds only. It is the reason `AnthropicDirectProvider` still exists:
/// generation can be exercised without deploying the proxy, using a key that
/// belongs to whoever is debugging.
public struct DirectRoute: ProviderRoute {
    private let keyStore: any APIKeyStore

    public init(keyStore: any APIKeyStore) {
        self.keyStore = keyStore
    }

    public func httpRequest(
        for request: MessagesRequest,
        kind: UsageKind,
        context: CallContext
    ) async throws -> HTTPRequest {
        guard let url = AnthropicAPI.messagesURL else {
            throw LessonProviderError.network("invalid API base URL")
        }
        guard let key = await keyStore.currentKey(), !key.isEmpty else {
            throw LessonProviderError.missingAPIKey
        }
        return HTTPRequest(
            url: url,
            headers: MessagesRequest.headers(apiKey: key),
            body: try request.encodedBody()
        )
    }
}

// MARK: - Proxy

/// Device → Spare proxy → Anthropic.
///
/// The shipping path. No key on the device: the proxy holds it in a secret
/// binding, and the device presents only an identifier and, if there is one, a
/// subscription receipt.
///
/// The request body the app builds is nested under `request` rather than sent
/// at the top level. The proxy needs its own fields alongside it, and nesting
/// keeps the two sets from ever colliding — a future Anthropic parameter called
/// `topic` would otherwise silently become a metering field.
public struct ProxyRoute: ProviderRoute {
    /// The proxy's origin, e.g. `https://spare-proxy.<subdomain>.workers.dev`.
    private let baseURL: URL
    private let deviceID: String
    /// The current subscription's JWS, or nil when there isn't one.
    ///
    /// A closure rather than a stored value because entitlement changes while
    /// the app runs — a purchase, a restore, an expiry — and a receipt captured
    /// at construction would keep a lapsed subscriber premium until relaunch.
    /// Async and `Sendable` because on device this reads StoreKit, which
    /// SpareCore cannot import.
    private let receipt: @Sendable () async -> String?
    /// The proxy's operator token, or nil.
    ///
    /// Present only for the offline batch tool, which needs to generate more
    /// lessons in a sitting than any device is allowed. The app never sets it:
    /// `SpareApp` constructs `ProxyProvider` without this argument, and there is
    /// no user-facing way to supply one. Sending it makes the server skip the
    /// per-device limits and the cache — not the spend ceiling, and not the
    /// request policy.
    private let operatorToken: String?

    public init(
        baseURL: URL,
        deviceID: String,
        receipt: @escaping @Sendable () async -> String? = { nil },
        operatorToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.receipt = receipt
        self.operatorToken = operatorToken
    }

    /// One endpoint per kind of call, mirroring `LessonProvider`'s methods.
    ///
    /// Draft and revision passes of the same lesson share an endpoint: they are
    /// one lesson to the reader and must be one unit to the meter. Charging a
    /// free user's daily lesson twice because generation happens in two passes
    /// would be an implementation detail leaking into the price.
    static func path(for kind: UsageKind) -> String {
        switch kind {
        case .suggestions:
            return "/v1/suggestions"
        case .courseOutline, .lessonDraft, .lessonRevision:
            return "/v1/lesson"
        case .chapterDraft, .chapterRevision:
            return "/v1/chapter"
        case .recallQuestion:
            return "/v1/recall"
        case .postLessonTest:
            return "/v1/post-lesson-test"
        case .goDeeperDraft, .goDeeperRevision:
            return "/v1/go-deeper"
        }
    }

    public func httpRequest(
        for request: MessagesRequest,
        kind: UsageKind,
        context: CallContext
    ) async throws -> HTTPRequest {
        let path = Self.path(for: kind)
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw LessonProviderError.network("invalid proxy URL")
        }

        var envelope: [String: JSONValue] = [
            "window": .string(context.window.rawValue),
            "format": .string(context.format.rawValue),
            "topic": .string(context.topic),
            "request": request.jsonBody,
        ]
        if let receipt = await receipt(), !receipt.isEmpty {
            envelope["receipt"] = .string(receipt)
        }

        var headers = [
            "content-type": "application/json",
            "x-spare-device": deviceID,
        ]
        // The proxy answers SSE on the streaming endpoints. Declared so an
        // intermediary has no excuse to buffer.
        if request.stream {
            headers["accept"] = "text/event-stream"
        }
        if let operatorToken, !operatorToken.isEmpty {
            headers["x-spare-admin"] = operatorToken
        }

        return HTTPRequest(
            url: url,
            headers: headers,
            body: try Self.encode(JSONValue.object(envelope))
        )
    }

    /// Sorted keys so a fixture can assert on the exact bytes.
    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
