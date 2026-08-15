import Foundation

/// Calls the Anthropic Messages API directly from the device.
///
/// Everything goes through `HTTPTransport`, so the whole provider — including
/// the two-pass pipeline, retry behaviour, and lazy chapter generation — is
/// exercised in CI against recorded fixtures with no network and no API key.
///
/// Cost discipline is built in rather than bolted on:
/// - the editorial system prompt is stable and cached, so the bulk of every
///   request's input is billed at cache-read rates after the first call;
/// - chaptered lessons block on `ChapterDemand`, so unread chapters are never
///   generated;
/// - every call writes to `UsageLedger`, so the monthly figure in Settings
///   reflects real spend rather than an estimate of intent.
public struct AnthropicDirectProvider: LessonProvider {

    public struct Configuration: Sendable {
        public var model: String
        public var effort: Effort?
        public var retry: RetryPolicy
        /// The editorial prompt is identical on every call, which is the whole
        /// point of caching it. Disable only to measure the difference.
        public var cacheSystemPrompt: Bool

        public init(
            model: String = AnthropicAPI.model,
            effort: Effort? = .high,
            retry: RetryPolicy = .standard,
            cacheSystemPrompt: Bool = true
        ) {
            self.model = model
            self.effort = effort
            self.retry = retry
            self.cacheSystemPrompt = cacheSystemPrompt
        }

        public static let standard = Configuration()
    }

    private let transport: any HTTPTransport
    private let keyStore: any APIKeyStore
    private let ledger: any UsageLedger
    private let sleeper: any Sleeper
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport,
        keyStore: any APIKeyStore,
        ledger: any UsageLedger = NoopUsageLedger(),
        sleeper: any Sleeper = TaskSleeper(),
        configuration: Configuration = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.ledger = ledger
        self.sleeper = sleeper
        self.configuration = configuration
        self.now = now
    }

    // MARK: - Suggestions

    public func suggestTopics(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) async throws -> [TopicSuggestion] {
        var attempt = 0
        while true {
            let request = MessagesRequest(
                model: configuration.model,
                maxTokens: 4_000,
                system: Prompts.suggestionSystemPrompt,
                messages: [.user(Prompts.suggestionTaskPrompt(
                    window: window, profile: profile, history: history
                ))],
                effort: configuration.effort,
                outputSchema: Schemas.topicSuggestions,
                cacheSystemPrompt: configuration.cacheSystemPrompt
            )

            let decoded: TopicSuggestionsResponse = try await sendStructured(
                request, kind: .suggestions
            )
            let issues = SuggestionValidator.validate(
                decoded.suggestions, history: history, profile: profile
            )

            // One regeneration for a structurally wrong set (too few domains,
            // no wildcard, a repeat). Beyond that, take what we have rather
            // than spend indefinitely chasing a perfect set.
            if issues.contains(where: \.isBlocking), attempt < 1 {
                attempt += 1
                continue
            }
            return SuggestionValidator.repairing(decoded.suggestions)
        }
    }

    // MARK: - Recall

    public func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion {
        let request = MessagesRequest(
            model: configuration.model,
            maxTokens: 2_000,
            system: Prompts.recallSystemPrompt,
            messages: [.user(Prompts.recallTaskPrompt(lesson: lesson))],
            effort: configuration.effort,
            outputSchema: Schemas.recallQuestion,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )
        return try await sendStructured(request, kind: .recallQuestion)
    }

    public func generatePostLessonTest(for lesson: Lesson) async throws -> [RecallQuestion] {
        let request = MessagesRequest(
            model: configuration.model,
            maxTokens: 3_500,
            system: Prompts.postLessonTestSystemPrompt,
            messages: [.user(Prompts.postLessonTestTaskPrompt(lesson: lesson))],
            effort: configuration.effort,
            outputSchema: Schemas.postLessonTest,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )
        let response: PostLessonTestResponse = try await sendStructured(request, kind: .postLessonTest)
        return response.normalizedQuestions
    }

    // MARK: - Go deeper

    public func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        let task = Prompts.goDeeperTaskPrompt(
            window: window, profile: profile, parentTitle: lesson.title, angle: angle
        )
        let draft: Lesson = try await sendStructured(
            MessagesRequest(
                model: configuration.model,
                maxTokens: AnthropicAPI.maxTokens(for: window),
                system: Prompts.editorialSystemPrompt,
                messages: [.user(task)],
                effort: configuration.effort,
                outputSchema: Schemas.lesson,
                cacheSystemPrompt: configuration.cacheSystemPrompt
            ),
            kind: .goDeeperDraft
        )

        // Same two-pass bar as a normal lesson: the reader is reading this
        // one too, so it does not get to skip revision.
        return try await sendStructured(
            revisionRequest(window: window, draft: draft),
            kind: .goDeeperRevision
        )
    }

    // MARK: - Streaming lessons

    public func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand
    ) -> AsyncThrowingStream<LessonStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if window.format.isChaptered {
                        try await runChapteredLesson(
                            topic: topic, window: window, profile: profile,
                            demand: demand, continuation: continuation
                        )
                    } else {
                        try await runSingleLesson(
                            topic: topic, window: window, profile: profile,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LessonProviderError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runSingleLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        continuation: AsyncThrowingStream<LessonStreamEvent, Error>.Continuation
    ) async throws {
        let draftRequest = MessagesRequest(
            model: configuration.model,
            maxTokens: AnthropicAPI.maxTokens(for: window),
            system: Prompts.editorialSystemPrompt,
            messages: [.user(Prompts.lessonTaskPrompt(
                topic: topic, window: window, profile: profile
            ))],
            stream: true,
            effort: configuration.effort,
            outputSchema: Schemas.lesson,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )

        // Pass 1. Streamed for progress and to avoid a long silent request,
        // but never displayed — `RevisionGate` drops draft text on the floor.
        let (draft, _) = try await streamStructured(
            request: draftRequest,
            field: "bodyMarkdown",
            kind: .lessonDraft,
            as: Lesson.self,
            retryAfterEmission: true
        ) { text in
            continuation.yield(.draftDelta(chapter: 0, text: text))
        }
        continuation.yield(.metadata(draft.metadata))
        continuation.yield(.draftChapterFinished(chapter: 0))

        // Pass 2. This is what the reader actually sees.
        let (revised, _) = try await streamStructured(
            request: revisionRequest(window: window, draft: draft, stream: true),
            field: "bodyMarkdown",
            kind: .lessonRevision,
            as: Lesson.self,
            retryAfterEmission: false
        ) { text in
            continuation.yield(.revisedDelta(chapter: 0, text: text))
        }
        continuation.yield(.revisedChapterFinished(chapter: 0))
        continuation.yield(.finished(revised))
    }

    private func runChapteredLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand,
        continuation: AsyncThrowingStream<LessonStreamEvent, Error>.Continuation
    ) async throws {
        let chapterCount = window.format.chapterCount

        let outline: CourseOutlineResponse = try await sendStructured(
            MessagesRequest(
                model: configuration.model,
                maxTokens: 4_000,
                system: Prompts.outlineSystemPrompt,
                messages: [.user(Prompts.outlineTaskPrompt(
                    topic: topic, window: window, profile: profile
                ))],
                effort: configuration.effort,
                outputSchema: Schemas.courseOutline,
                cacheSystemPrompt: configuration.cacheSystemPrompt
            ),
            kind: .courseOutline
        )
        continuation.yield(.metadata(outline.metadata))

        let headings = outline.headings(paddedTo: chapterCount)
        var chapterTexts: [String] = []

        for index in 0..<chapterCount {
            // The load-bearing line for cost: blocks until the reader is
            // close enough to want this chapter. A reader who stops at
            // chapter 2 leaves this suspended, and the task is cancelled
            // when they leave the Reader.
            if index > 0 {
                try await demand.waitUntilAllowed(chapter: index)
            }
            try Task.checkCancellation()

            let text = try await generateChapter(
                index: index,
                heading: headings[index],
                previousHeadings: Array(headings.prefix(index)),
                topic: topic,
                window: window,
                profile: profile,
                continuation: continuation
            )
            chapterTexts.append(text)
        }

        // Assembled exactly the way RevisionGate concatenates revised
        // chapters, so the canonical body it commits is byte-identical to
        // what the reader has already been shown.
        let lesson = Lesson(
            title: outline.title,
            subtitle: outline.subtitle,
            domainTag: outline.domainTag,
            bodyMarkdown: chapterTexts.joined(separator: "\n\n"),
            surprisingClaim: outline.surprisingClaim,
            deeperAngles: outline.deeperAngles
        )
        continuation.yield(.finished(lesson))
    }

    /// Both passes for one chapter. Returns the revised chapter markdown,
    /// heading included.
    private func generateChapter(
        index: Int,
        heading: String,
        previousHeadings: [String],
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        continuation: AsyncThrowingStream<LessonStreamEvent, Error>.Continuation
    ) async throws -> String {
        let task = Prompts.chapterTaskPrompt(
            topic: topic,
            window: window,
            profile: profile,
            chapterNumber: index + 1,
            heading: heading,
            previousHeadings: previousHeadings
        )
        let chapterRequest = MessagesRequest(
            model: configuration.model,
            maxTokens: AnthropicAPI.maxTokens(for: window),
            system: Prompts.editorialSystemPrompt,
            messages: [.user(task)],
            stream: true,
            effort: configuration.effort,
            outputSchema: Schemas.chapter,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )

        let (_, draftJSON) = try await streamStructured(
            request: chapterRequest,
            field: "bodyMarkdown",
            kind: .chapterDraft,
            as: ChapterResponse.self,
            retryAfterEmission: true
        ) { text in
            continuation.yield(.draftDelta(chapter: index, text: text))
        }
        continuation.yield(.draftChapterFinished(chapter: index))

        let revisionRequest = MessagesRequest(
            model: configuration.model,
            maxTokens: AnthropicAPI.maxTokens(for: window),
            system: Prompts.revisionSystemPrompt,
            messages: [.user(Prompts.revisionTaskPrompt(
                window: window, draftJSON: draftJSON
            ))],
            stream: true,
            effort: configuration.effort,
            outputSchema: Schemas.chapter,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )

        // The heading has to reach the reader before the body it heads, and
        // it only exists once its own JSON field closes — so body deltas are
        // held until then, then flushed.
        let headerPrefix = "## Chapter \(index + 1): "
        var headingExtractor = StreamingJSONFieldExtractor(field: "heading")
        var pendingBody = ""
        var headerEmitted = false

        let (revised, _) = try await streamStructured(
            request: revisionRequest,
            field: "bodyMarkdown",
            kind: .chapterRevision,
            as: ChapterResponse.self,
            retryAfterEmission: false,
            onRawDelta: { raw in
                _ = headingExtractor.consume(raw)
            }
        ) { bodyText in
            if !headerEmitted, headingExtractor.isFieldComplete {
                let resolved = headingExtractor.accumulated.isEmpty
                    ? heading
                    : headingExtractor.accumulated
                continuation.yield(.revisedDelta(
                    chapter: index, text: headerPrefix + resolved + "\n\n"
                ))
                headerEmitted = true
                if !pendingBody.isEmpty {
                    continuation.yield(.revisedDelta(chapter: index, text: pendingBody))
                    pendingBody = ""
                }
            }
            if headerEmitted {
                continuation.yield(.revisedDelta(chapter: index, text: bodyText))
            } else {
                pendingBody += bodyText
            }
        }

        // If the body was empty the header never flushed; emit it now so the
        // chapter is never silently missing its heading.
        if !headerEmitted {
            continuation.yield(.revisedDelta(
                chapter: index, text: headerPrefix + revised.heading + "\n\n"
            ))
            if !pendingBody.isEmpty {
                continuation.yield(.revisedDelta(chapter: index, text: pendingBody))
            }
        }
        continuation.yield(.revisedChapterFinished(chapter: index))

        let resolvedHeading = headerEmitted && !headingExtractor.accumulated.isEmpty
            ? headingExtractor.accumulated
            : revised.heading
        return headerPrefix + resolvedHeading + "\n\n" + revised.bodyMarkdown
    }

    private func revisionRequest(
        window: TimeWindow,
        draft: Lesson,
        stream: Bool = false
    ) -> MessagesRequest {
        let draftJSON = (try? encodeJSON(draft)) ?? draft.bodyMarkdown
        return MessagesRequest(
            model: configuration.model,
            maxTokens: AnthropicAPI.maxTokens(for: window),
            system: Prompts.revisionSystemPrompt,
            messages: [.user(Prompts.revisionTaskPrompt(window: window, draftJSON: draftJSON))],
            stream: stream,
            effort: configuration.effort,
            outputSchema: Schemas.lesson,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )
    }

    // MARK: - Non-streaming request

    private func sendStructured<T: Decodable>(
        _ request: MessagesRequest,
        kind: UsageKind
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                let key = try await resolvedKey()
                let response = try await transport.send(HTTPRequest(
                    url: try messagesURL(),
                    headers: MessagesRequest.headers(apiKey: key),
                    body: try request.encodedBody()
                ))
                guard response.isSuccess else {
                    throw HTTPTransportMapper.providerError(
                        status: response.statusCode, body: response.body
                    )
                }
                let parsed = try MessagesResponse.decode(response.body)
                await record(usage: parsed.usage, kind: kind)
                do {
                    return try parsed.decodePayload(T.self)
                } catch let error as LessonProviderError {
                    // A refusal is a decision, not a glitch — never retried.
                    if case .refused = error { throw error }
                    throw LessonProviderError.malformedStream("\(error)")
                }
            } catch {
                try await backoffOrThrow(error, attempt: &attempt)
            }
        }
    }

    // MARK: - Streaming request

    /// Streams one structured-output request, emitting the target field's text
    /// as it decodes.
    ///
    /// - Parameter retryAfterEmission: whether a failure *after* text has
    ///   already been handed to the caller may be retried. False for revision
    ///   passes: those deltas are already on the reader's screen, and
    ///   re-running the pass would append a second copy rather than replace
    ///   the first. True for drafts, which are never displayed.
    /// Decoding happens *inside* the retry loop, not after it: a response that
    /// streams cleanly but doesn't parse is exactly the "malformed response"
    /// case that should be retried, and decoding outside would surface it as
    /// a hard failure on the first attempt.
    private func streamStructured<T: Decodable>(
        request: MessagesRequest,
        field: String,
        kind: UsageKind,
        as type: T.Type,
        retryAfterEmission: Bool,
        onRawDelta: ((String) -> Void)? = nil,
        onDelta: (String) -> Void
    ) async throws -> (value: T, json: String) {
        var attempt = 1
        while true {
            do {
                return try await streamStructuredOnce(
                    request: request,
                    field: field,
                    kind: kind,
                    as: type,
                    onRawDelta: onRawDelta,
                    onDelta: onDelta
                )
            } catch let failure as StreamAttemptFailure {
                if failure.didEmit && !retryAfterEmission {
                    throw failure.underlying
                }
                try await backoffOrThrow(failure.underlying, attempt: &attempt)
            }
        }
    }

    /// Wraps an attempt's error with whether it had already emitted text, so
    /// the retry decision above can be made without capturing mutable state
    /// in a closure.
    private struct StreamAttemptFailure: Error {
        let underlying: Error
        let didEmit: Bool
    }

    private func streamStructuredOnce<T: Decodable>(
        request: MessagesRequest,
        field: String,
        kind: UsageKind,
        as type: T.Type,
        onRawDelta: ((String) -> Void)?,
        onDelta: (String) -> Void
    ) async throws -> (value: T, json: String) {
        var didEmit = false
        var parser = SSEParser()
        var extractor = StreamingJSONFieldExtractor(field: field)
        var fullJSON = ""
        var usage = TokenUsage()
        var stopReason: String?
        var sawMessageStop = false
        var streamError: LessonProviderError?

        func handle(_ event: SSEEvent) {
            if let startUsage = AnthropicStreamDecoder.usage(from: event) {
                usage.inputTokens = max(usage.inputTokens, startUsage.inputTokens)
                usage.cacheCreationInputTokens = max(
                    usage.cacheCreationInputTokens, startUsage.cacheCreationInputTokens
                )
                usage.cacheReadInputTokens = max(
                    usage.cacheReadInputTokens, startUsage.cacheReadInputTokens
                )
                if startUsage.outputTokens > 0 {
                    usage.outputTokens = max(usage.outputTokens, startUsage.outputTokens)
                }
            }

            switch AnthropicStreamDecoder.decode(event) {
            case .textDelta(let text):
                fullJSON += text
                onRawDelta?(text)
                let decoded = extractor.consume(text)
                if !decoded.isEmpty {
                    onDelta(decoded)
                    didEmit = true
                }
            case .messageDelta(let reason, let outputTokens):
                stopReason = reason
                if let outputTokens {
                    usage.outputTokens = max(usage.outputTokens, outputTokens)
                }
            case .messageStop:
                sawMessageStop = true
            case .error(let type, let message):
                streamError = LessonProviderError.httpStatus(
                    code: Self.statusCode(forStreamErrorType: type), message: message
                )
            default:
                break
            }
        }

        do {
            let key = try await resolvedKey()
            let httpRequest = HTTPRequest(
                url: try messagesURL(),
                headers: MessagesRequest.headers(apiKey: key),
                body: try request.encodedBody()
            )

            for try await chunk in transport.stream(httpRequest) {
                try Task.checkCancellation()
                for event in parser.consume(chunk) {
                    handle(event)
                }
                if let streamError { throw streamError }
            }
            for event in parser.finish() {
                handle(event)
            }
            if let streamError { throw streamError }

            await record(usage: usage, kind: kind)

            if stopReason == "refusal" {
                throw LessonProviderError.refused(category: nil, explanation: nil)
            }
            guard !fullJSON.isEmpty else {
                throw LessonProviderError.malformedStream("stream produced no content")
            }
            guard sawMessageStop else {
                throw LessonProviderError.malformedStream("stream ended before message_stop")
            }
            if stopReason == "max_tokens" {
                throw LessonProviderError.malformedStream("response was cut off at max_tokens")
            }
            return (try decode(type, from: fullJSON), fullJSON)
        } catch let failure as StreamAttemptFailure {
            throw failure
        } catch {
            // Usage is still recorded for a failed attempt: those tokens were
            // billed whether or not we could use the result.
            if usage.inputTokens > 0 || usage.outputTokens > 0 {
                await record(usage: usage, kind: kind)
            }
            throw StreamAttemptFailure(underlying: normalized(error), didEmit: didEmit)
        }
    }

    // MARK: - Shared helpers

    private func backoffOrThrow(_ error: Error, attempt: inout Int) async throws {
        let normalizedError = normalized(error)
        if case .cancelled = normalizedError { throw normalizedError }
        try Task.checkCancellation()

        let retryable = normalizedError.isRetryable
        guard attempt < configuration.retry.maxAttempts, retryable else {
            throw normalizedError
        }
        try await sleeper.sleep(seconds: configuration.retry.delay(beforeAttempt: attempt + 1))
        attempt += 1
    }

    private func normalized(_ error: Error) -> LessonProviderError {
        if let providerError = error as? LessonProviderError { return providerError }
        if error is CancellationError { return .cancelled }
        return .network(String(describing: error))
    }

    private func resolvedKey() async throws -> String {
        guard let key = await keyStore.currentKey(), !key.isEmpty else {
            throw LessonProviderError.missingAPIKey
        }
        return key
    }

    private func messagesURL() throws -> URL {
        guard let url = AnthropicAPI.messagesURL else {
            throw LessonProviderError.network("invalid API base URL")
        }
        return url
    }

    private func record(usage: TokenUsage, kind: UsageKind) async {
        guard usage.inputTokens > 0 || usage.outputTokens > 0
            || usage.cacheReadInputTokens > 0 || usage.cacheCreationInputTokens > 0
        else { return }
        await ledger.record(UsageEvent(
            kind: kind, model: configuration.model, usage: usage, occurredAt: now()
        ))
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw LessonProviderError.malformedStream("response was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LessonProviderError.malformedStream("could not decode \(type): \(error)")
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LessonProviderError.decoding("could not encode \(T.self)")
        }
        return text
    }

    static func statusCode(forStreamErrorType type: String) -> Int {
        switch type {
        case "overloaded_error": return 529
        case "rate_limit_error": return 429
        case "api_error": return 500
        case "authentication_error": return 401
        default: return 400
        }
    }
}
