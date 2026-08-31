import Foundation

/// Why a pass is being run again, and what the re-run has to be told.
///
/// Replaces the bare `Int?` shortfall now that two different checks can spend
/// the same retry. A bare re-run is the same request twice and lands in the
/// same place often enough not to be worth the money, so each case carries the
/// one thing the model cannot see for itself: what it produced last time.
public enum RetryReason: Equatable, Sendable {
    /// The previous attempt came in under the word floor.
    case short(words: Int)
    /// The previous attempt used a banned construction. Carries the sentence
    /// verbatim, because naming the shape without naming the instance has
    /// already been tried three times in the prompt and did not work.
    case bannedConstruction(sentence: String)
}

/// The two-pass generation pipeline, independent of where requests are sent.
///
/// Draft, revision, quality checks, retry behaviour, and lazy chapter
/// generation are the same whether the request goes straight to Anthropic with
/// the user's own key or through the Spare proxy. Only the URL, the headers, and
/// the body envelope differ, and a `ProviderRoute` supplies those — so the two
/// transports cannot drift apart in the parts that decide what a lesson reads
/// like. `AnthropicDirectProvider` and `ProxyProvider` are both this type with a
/// different route.
///
/// Everything goes through `HTTPTransport`, so the whole pipeline is exercised
/// in CI against recorded fixtures with no network and no API key.
///
/// Cost discipline is built in rather than bolted on:
/// - the editorial system prompt is stable and cached, so the bulk of every
///   request's input is billed at cache-read rates after the first call;
/// - chaptered lessons block on `ChapterDemand`, so unread chapters are never
///   generated;
/// - every call writes to `UsageLedger`, so the monthly figure in Settings
///   reflects real spend rather than an estimate of intent.
public struct GenerationPipeline: LessonProvider {

    public struct Configuration: Sendable {
        public var model: String
        public var effort: Effort?
        public var retry: RetryPolicy
        /// The editorial prompt is identical on every call, which is the whole
        /// point of caching it. Disable only to measure the difference.
        public var cacheSystemPrompt: Bool
        /// Extra attempts allowed at a pass that came back under the word floor
        /// **or** carrying a banned construction.
        ///
        /// One, not three, and one *shared between both checks* rather than one
        /// each. Each attempt is a whole pass at full price, and the server
        /// bounds how many requests one lesson may make: at one retry a
        /// course's worst case is an outline plus four chapters of two drafts
        /// and two revisions, which is seventeen calls and is what
        /// `MAX_REQUESTS_PER_LESSON` was raised to cover. A second retry would
        /// put it past that bound and turn a length problem into a 402 halfway
        /// through chapter three — and so would giving the construction check a
        /// budget of its own, which is why `respectingQuality` decrements one
        /// counter for both.
        ///
        /// Named for quality rather than the floor since the construction check
        /// joined it: leaving it `wordFloorRetries` would say the budget is the
        /// floor's alone, which is the misreading that breaks the bound above.
        public var qualityRetries: Int
        /// Whether a pass that lands under the word floor is retried and, in the
        /// end, refused.
        ///
        /// On everywhere that generates. Off in tests whose subject is the
        /// transport — retries, metering, header shape, event ordering — because
        /// a queued fixture is a stub and not a generation. Making every such
        /// fixture carry four hundred words of filler to satisfy a rule about
        /// reading time would say nothing true about the model and would bury
        /// what those tests are actually asserting.
        ///
        /// Tests that are about the floor keep it on and use bodies of a real
        /// length. `Configuration.standard` enforces.
        public var enforcesWordFloor: Bool

        public init(
            model: String = AnthropicAPI.model,
            effort: Effort? = .high,
            retry: RetryPolicy = .standard,
            cacheSystemPrompt: Bool = true,
            qualityRetries: Int = 1,
            enforcesWordFloor: Bool = true
        ) {
            self.model = model
            self.effort = effort
            self.retry = retry
            self.cacheSystemPrompt = cacheSystemPrompt
            self.qualityRetries = max(0, qualityRetries)
            self.enforcesWordFloor = enforcesWordFloor
        }

        public static let standard = Configuration()
    }

    private let transport: any HTTPTransport
    private let route: any ProviderRoute
    private let ledger: any UsageLedger
    private let sleeper: any Sleeper
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport,
        route: any ProviderRoute,
        ledger: any UsageLedger = NoopUsageLedger(),
        sleeper: any Sleeper = TaskSleeper(),
        configuration: Configuration = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.route = route
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
                request, kind: .suggestions, context: .plain(window: window)
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
        return try await sendStructured(
            request, kind: .recallQuestion, context: .about(lesson)
        )
    }

    public func generatePostLessonTest(
        for lesson: Lesson,
        window: TimeWindow
    ) async throws -> [RecallQuestion] {
        let request = MessagesRequest(
            model: configuration.model,
            maxTokens: 3_500,
            system: Prompts.postLessonTestSystemPrompt,
            messages: [.user(Prompts.postLessonTestTaskPrompt(
                lesson: lesson, questionCount: window.testQuestionCount
            ))],
            effort: configuration.effort,
            outputSchema: Schemas.postLessonTest(questionCount: window.testQuestionCount),
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )
        let response: PostLessonTestResponse = try await sendStructured(
            request, kind: .postLessonTest, context: .about(lesson)
        )
        return response.normalizedQuestions(count: window.testQuestionCount)
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
        // The angle, not the parent lesson, is the subject being written about.
        let deeperContext = CallContext(
            window: window, format: window.format, topic: angle.text
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
            kind: .goDeeperDraft,
            context: deeperContext
        )

        // Same two-pass bar as a normal lesson: the reader is reading this
        // one too, so it does not get to skip revision.
        return try await sendStructured(
            revisionRequest(window: window, draft: draft),
            kind: .goDeeperRevision,
            context: deeperContext
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
        let context = CallContext(
            window: window, format: window.format,
            topic: topic.title, interest: topic.domainTag
        )
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
        //
        // The floor check here is the free one: nothing has been shown, so a
        // re-run costs a call and no reader ever knows. It does not refuse.
        let draft = try await respectingQuality(
            budget: window.wordBudget,
            throwOnExhaustion: false,
            wordCount: { (lesson: Lesson) in lesson.wordCount },
            body: { (lesson: Lesson) in lesson.bodyMarkdown },
            runPass: { _ in
                let (draft, _) = try await streamStructured(
                    request: draftRequest,
                    field: "bodyMarkdown",
                    kind: .lessonDraft,
                    context: context,
                    as: Lesson.self,
                    retryAfterEmission: true
                ) { text in
                    continuation.yield(.draftDelta(chapter: 0, text: text))
                }
                return draft
            }
        )
        continuation.yield(.metadata(draft.metadata))
        continuation.yield(.draftChapterFinished(chapter: 0))

        // Pass 2. This is what the reader actually sees, so a re-run has to
        // take back what the last attempt put on their screen.
        let revised = try await respectingQuality(
            budget: window.wordBudget,
            wordCount: { (lesson: Lesson) in lesson.wordCount },
            body: { (lesson: Lesson) in lesson.bodyMarkdown },
            onWithdraw: { continuation.yield(.revisionRestarted(chapter: 0)) },
            // Follows the withdrawal above, so the reader is shown the attempt
            // being kept rather than the one just discarded.
            onRestore: { (kept: Lesson) in
                continuation.yield(.revisedDelta(chapter: 0, text: kept.bodyMarkdown))
            },
            runPass: { retry in
                let (revised, _) = try await streamStructured(
                    request: revisionRequest(
                        window: window, draft: draft, stream: true, retry: retry
                    ),
                    field: "bodyMarkdown",
                    kind: .lessonRevision,
                    context: context,
                    as: Lesson.self,
                    retryAfterEmission: false
                ) { text in
                    continuation.yield(.revisedDelta(chapter: 0, text: text))
                }
                return revised
            }
        )
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
        let context = CallContext(
            window: window, format: window.format,
            topic: topic.title, interest: topic.domainTag
        )
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
            kind: .courseOutline,
            context: context
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
        // The chapter index travels with the call: the proxy stores one body
        // per chapter, and without it they all land on one key.
        let context = CallContext(
            window: window, format: window.format,
            topic: topic.title, interest: topic.domainTag, chapterIndex: index
        )
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

        // Measured against the chapter's budget, not the course's. Same rule
        // as the revision below, and the same mistake if it is got wrong.
        var draftJSON = ""
        _ = try await respectingQuality(
            budget: window.chapterWordBudget,
            throwOnExhaustion: false,
            wordCount: { (chapter: ChapterResponse) in chapter.bodyMarkdown.lessonWordCount },
            body: { (chapter: ChapterResponse) in chapter.bodyMarkdown },
            runPass: { _ in
                let (draft, json) = try await streamStructured(
                    request: chapterRequest,
                    field: "bodyMarkdown",
                    kind: .chapterDraft,
                    context: context,
                    as: ChapterResponse.self,
                    retryAfterEmission: true
                ) { text in
                    continuation.yield(.draftDelta(chapter: index, text: text))
                }
                draftJSON = json
                return draft
            }
        )
        continuation.yield(.draftChapterFinished(chapter: index))

        // The heading has to reach the reader before the body it heads, and
        // it only exists once its own JSON field closes — so body deltas are
        // held until then, then flushed.
        let headerPrefix = "\(LessonFormat.chapterHeadingPrefix)\(index + 1): "
        var resolvedHeading = heading

        let revised = try await respectingQuality(
            budget: window.chapterWordBudget,
            wordCount: { (chapter: ChapterResponse) in chapter.bodyMarkdown.lessonWordCount },
            body: { (chapter: ChapterResponse) in chapter.bodyMarkdown },
            onWithdraw: { continuation.yield(.revisionRestarted(chapter: index)) },
            // Header and body together, in the same shape the streaming path
            // assembles them (see the return below), so a restored chapter is
            // not left headless.
            onRestore: { (kept: ChapterResponse) in
                continuation.yield(.revisedDelta(
                    chapter: index,
                    text: headerPrefix + kept.heading + "

" + kept.bodyMarkdown
                ))
                // Track it too. The assembled return below reads
                // `resolvedHeading`, which still holds the *discarded*
                // attempt's heading at this point — leaving it would pair one
                // attempt's heading with another's body.
                resolvedHeading = kept.heading
            },
            runPass: { retry in
                let revisionRequest = MessagesRequest(
                    model: configuration.model,
                    maxTokens: AnthropicAPI.maxTokens(for: window),
                    system: Prompts.revisionSystemPrompt,
                    // The chapter's budget, not the course's. See the note on
                    // `revisionTaskPrompt`.
                    messages: [.user(Prompts.revisionTaskPrompt(
                        wordBudget: window.chapterWordBudget,
                        draftJSON: draftJSON,
                        retry: retry
                    ))],
                    stream: true,
                    effort: configuration.effort,
                    outputSchema: Schemas.chapter,
                    cacheSystemPrompt: configuration.cacheSystemPrompt
                )

                // Per attempt, not per chapter. A withdrawn revision takes its
                // header back along with its body, so the next attempt has to emit
                // one again — state carried over from the last attempt would leave
                // the chapter headless.
                var headingExtractor = StreamingJSONFieldExtractor(field: "heading")
                var pendingBody = ""
                var headerEmitted = false

                let (revised, _) = try await streamStructured(
                    request: revisionRequest,
                    field: "bodyMarkdown",
                    kind: .chapterRevision,
                    context: context,
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

                resolvedHeading = headerEmitted && !headingExtractor.accumulated.isEmpty
                    ? headingExtractor.accumulated
                    : revised.heading
                return revised
            }
        )

        // After the floor check, never before: this is what tells the gate the
        // chapter is done and the Reader to persist it.
        continuation.yield(.revisedChapterFinished(chapter: index))

        return headerPrefix + resolvedHeading + "\n\n" + revised.bodyMarkdown
    }

    private func revisionRequest(
        window: TimeWindow,
        draft: Lesson,
        stream: Bool = false,
        retry: RetryReason? = nil
    ) -> MessagesRequest {
        let draftJSON = (try? encodeJSON(draft)) ?? draft.bodyMarkdown
        return MessagesRequest(
            model: configuration.model,
            maxTokens: AnthropicAPI.maxTokens(for: window),
            system: Prompts.revisionSystemPrompt,
            // A whole lesson, so the whole window's budget.
            messages: [.user(Prompts.revisionTaskPrompt(
                wordBudget: window.wordBudget,
                draftJSON: draftJSON,
                retry: retry
            ))],
            stream: stream,
            effort: configuration.effort,
            outputSchema: Schemas.lesson,
            cacheSystemPrompt: configuration.cacheSystemPrompt
        )
    }

    // MARK: - Non-streaming request

    private func sendStructured<T: Decodable>(
        _ request: MessagesRequest,
        kind: UsageKind,
        context: CallContext
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                let response = try await transport.send(
                    try await route.httpRequest(for: request, kind: kind, context: context)
                )
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
        context: CallContext,
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
                    context: context,
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
        context: CallContext,
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
            let httpRequest = try await route.httpRequest(
                for: request, kind: kind, context: context
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

    // MARK: - Word floor

    /// Runs a pass, and runs it again if what came back is materially shorter
    /// than the length the reader chose.
    ///
    /// The check sits here rather than in the caller because of what it costs
    /// to get wrong in either direction. Serving the short lesson breaks the
    /// product's one promise — a 15-minute lesson at 1,555 words is about
    /// eight minutes of reading — and refusing it on the first attempt throws
    /// away a whole generation over something a second pass usually fixes, now
    /// that the revision prompt is told the floor matters.
    ///
    /// - Parameters:
    ///   - budget: the budget for *this* pass. A chapter is measured against a
    ///     chapter's budget, never the course's.
    ///   - throwOnExhaustion: false for drafts. A short draft is not yet a
    ///     failed lesson — the revision pass is now instructed to take a thin
    ///     argument further, so refusing here would reject lessons the next
    ///     call would have fixed. The revision's own check is the one that
    ///     decides.
    ///   - onWithdraw: called before each re-run, for a pass whose output has
    ///     already reached the reader. Drafts pass nothing: they are never
    ///     displayed, so there is nothing to take back.
    ///   - body: the prose to check for banned constructions. Separate from
    ///     `wordCount` because a chapter is not a `Lesson` and both paths need
    ///     the same check.
    ///   - onRestore: called with the attempt being kept when it is *not* the
    ///     one just run — see `rank`. Immediately follows an `onWithdraw`, so a
    ///     displayed pass can put the kept text back.
    ///   - runPass: given why the last attempt is being re-run, or nil first
    ///     time. Not a word count any more: two different checks can spend this
    ///     budget and the re-run has to be told which one did.
    private func respectingQuality<T>(
        budget: ClosedRange<Int>,
        throwOnExhaustion: Bool = true,
        wordCount: (T) -> Int,
        body: (T) -> String,
        onWithdraw: () -> Void = {},
        onRestore: (T) -> Void = { _ in },
        runPass: (_ previous: RetryReason?) async throws -> T
    ) async throws -> T {
        guard configuration.enforcesWordFloor else { return try await runPass(nil) }

        var reason: RetryReason?
        // ONE counter for both checks. Not tidiness — a budget each would put a
        // course's worst case at 1 outline + 4 chapters x (3 drafts + 3
        // revisions) = 25 calls, past `MAX_REQUESTS_PER_LESSON` (24), turning a
        // style problem into a 402 halfway through chapter three. Sharing holds
        // the worst case at the 17 that bound was raised to cover.
        var retriesLeft = configuration.qualityRetries
        var best: T?

        while true {
            let result = try await runPass(reason)
            let words = wordCount(result)
            let failure = LessonQualityCheck.failure(wordCount: words, budget: budget)
            let finding = LessonQualityCheck.retryTriggeringFindings(inBody: body(result)).first

            if failure == nil, finding == nil { return result }

            // Ties keep the current attempt, so an equally-bad re-run never
            // costs a pointless rewind.
            var keepingCurrent = false
            if best == nil
                || rank(result, budget: budget, wordCount: wordCount, body: body)
                    <= rank(best!, budget: budget, wordCount: wordCount, body: body) {
                best = result
                keepingCurrent = true
            }

            guard retriesLeft > 0 else {
                let keep = best ?? result
                if !keepingCurrent {
                    onWithdraw()
                    onRestore(keep)
                }
                // Only the failure tier may block. A finding never does: a
                // lesson carrying the construction is still a lesson, and
                // refusing to serve one over a sentence shape would be the
                // wrong trade in the expensive direction.
                if LessonQualityCheck.failure(wordCount: wordCount(keep), budget: budget) != nil {
                    guard throwOnExhaustion else { return keep }
                    throw LessonProviderError.underWordFloor(
                        words: wordCount(keep), floor: budget.lowerBound
                    )
                }
                return keep
            }

            retriesLeft -= 1
            // The floor is the more serious of the two, so it names the reason
            // when both are true.
            if failure != nil {
                reason = .short(words: words)
            } else if let sentence = finding?.offendingSentence {
                reason = .bannedConstruction(sentence: sentence)
            } else {
                reason = nil
            }
            onWithdraw()
        }
    }

    /// Lower is better.
    ///
    /// The floor dominates, and that ordering is the whole safety property. A
    /// construction-triggered re-run rolls the word count again, so without it
    /// a lesson that was the promised length could be traded for a shorter one
    /// that merely avoids a sentence shape — and on the revision pass, where
    /// exhaustion throws, that trade turns a stylistic tic into a generation
    /// failure the reader sees. Ranked this way the construction check can
    /// never make length worse than it found it.
    private func rank<T>(
        _ candidate: T,
        budget: ClosedRange<Int>,
        wordCount: (T) -> Int,
        body: (T) -> String
    ) -> Int {
        let meetsFloor = LessonQualityCheck.failure(
            wordCount: wordCount(candidate), budget: budget
        ) == nil
        let clean = LessonQualityCheck.retryTriggeringFindings(inBody: body(candidate)).isEmpty
        switch (meetsFloor, clean) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return 2
        case (false, false): return 3
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

// MARK: - Non-streaming convenience

extension GenerationPipeline {
    /// Non-streaming whole-lesson generation, both passes. The Reader always
    /// streams; this exists for callers that want a finished lesson in hand.
    ///
    /// Lives on the pipeline rather than on either provider, so the two get
    /// identical behaviour from it rather than one of them getting it by
    /// accident of which file the extension happened to sit in.
    public func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        var result: Lesson?
        for try await event in streamLesson(
            topic: topic, window: window, profile: profile, demand: .eager()
        ) {
            if case .finished(let lesson) = event { result = lesson }
        }
        guard let result else {
            throw LessonProviderError.malformedStream("lesson stream finished without a result")
        }
        return result
    }
}
