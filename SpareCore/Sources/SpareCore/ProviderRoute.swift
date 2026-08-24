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
    /// The interest category the lesson is being generated under, from the
    /// suggestion's `domainTag`.
    ///
    /// Known before generation, which is the requirement: the premium pool is
    /// keyed on it so retrieval can match a reader's stated interests, and a
    /// key that could only be computed from the finished lesson would be no
    /// use for a lookup. The free pool ignores it.
    public var interest: String
    /// Which chapter of a course this call is for, zero-based. Nil for
    /// everything that is not a chapter.
    ///
    /// The proxy caches one body per chapter. Without an index every chapter
    /// of a course collides on a single key, each overwriting the last, and
    /// what comes back is whichever chapter finished most recently served as
    /// the whole course.
    public var chapterIndex: Int?

    public init(
        window: TimeWindow,
        format: LessonFormat,
        topic: String = "",
        interest: String = "",
        chapterIndex: Int? = nil
    ) {
        self.window = window
        self.format = format
        self.topic = topic
        self.interest = interest
        self.chapterIndex = chapterIndex
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
        return CallContext(
            window: window, format: window.format,
            topic: lesson.title, interest: lesson.domainTag
        )
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
            body: try request.encodedBody(),
            timeout: AnthropicAPI.timeout(for: kind)
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

    /// Endpoints whose requests the proxy forces to `stream: true`.
    ///
    /// Mirrors `STREAMING_ENDPOINTS` in `server/src/policy.ts`, and exists so
    /// the mirror can be asserted. The proxy rebuilds every request from an
    /// allowlist and sets `stream` from the endpoint, never from what the
    /// client sent — so a non-streaming call routed to one of these is not a
    /// mismatch that degrades, it is a request that cannot work.
    ///
    /// That is what happened to the course outline. It is a small structured
    /// JSON call, it was routed to `/v1/lesson` because an outline is part of
    /// starting a lesson, and the proxy turned it into a streaming request.
    /// Every 30-minute course requested through the proxy failed, and neither
    /// side's tests could see it: the fixtures here decide what comes back, and
    /// the server's tests build their own request bodies.
    static let streamingPaths: Set<String> = ["/v1/lesson", "/v1/chapter"]

    /// One endpoint per kind of call, mirroring `LessonProvider`'s methods.
    ///
    /// Draft and revision passes of the same lesson share an endpoint: they are
    /// one lesson to the reader and must be one unit to the meter. Charging a
    /// free user's daily lesson twice because generation happens in two passes
    /// would be an implementation detail leaking into the price.
    ///
    /// The outline has its own endpoint rather than sharing the lesson's,
    /// because it is the one generation call that is not streamed.
    /// Whether this call produces text a reader will actually be shown.
    ///
    /// Draft passes do not. They are internal input to the revision pass and
    /// `RevisionGate` drops them on the floor -- so caching one would put
    /// unrevised prose into the pool, where the next reader would be served it
    /// as a finished lesson. That hole was always there; it becomes worth
    /// closing now that both tiers read the cache and a poisoned entry has a
    /// thirty-day life.
    static func producesFinalText(_ kind: UsageKind) -> Bool {
        switch kind {
        case .lessonDraft, .chapterDraft, .goDeeperDraft:
            return false
        case .lessonRevision, .chapterRevision, .goDeeperRevision,
             .courseOutline, .suggestions, .recallQuestion, .postLessonTest:
            return true
        }
    }

    static func path(for kind: UsageKind) -> String {
        switch kind {
        case .suggestions:
            return "/v1/suggestions"
        case .courseOutline:
            return "/v1/outline"
        case .lessonDraft, .lessonRevision:
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
            "interest": .string(context.interest),
            // Which pass this is. The proxy caches only final text; see
            // `producesFinalText`.
            "pass": .string(Self.producesFinalText(kind) ? "final" : "draft"),
            "request": request.jsonBody,
        ]
        if let chapterIndex = context.chapterIndex {
            envelope["chapter"] = .int(chapterIndex)
        }
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
            body: try Self.encode(JSONValue.object(envelope)),
            timeout: AnthropicAPI.timeout(for: kind)
        )
    }

    /// Sorted keys so a fixture can assert on the exact bytes.
    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
