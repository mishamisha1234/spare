import Foundation

/// Deterministic offline provider for tests, previews, and no-key mode.
///
/// Fixture bodies are sized to land inside each window's word budget, and the
/// stream emits draft-then-revision per chapter in the same order the real
/// provider does, so `RevisionGate` behaviour can be tested end to end.
public struct MockProvider: LessonProvider {

    /// Disable for instant results in unit tests.
    public var simulateLatency: Bool
    /// Milliseconds between streamed chunks when latency is simulated.
    public var chunkDelayMilliseconds: UInt64

    public init(simulateLatency: Bool = true, chunkDelayMilliseconds: UInt64 = 45) {
        self.simulateLatency = simulateLatency
        self.chunkDelayMilliseconds = chunkDelayMilliseconds
    }

    // MARK: - Suggestions

    public func suggestTopics(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) async throws -> [TopicSuggestion] {
        try await pause(milliseconds: 350)
        return Self.fixtureSuggestions(for: window)
    }

    public static func fixtureSuggestions(for window: TimeWindow) -> [TopicSuggestion] {
        // 5 suggestions, 5 domains, exactly one wildcard.
        // Titles <= 7 words, hooks <= 14 words.
        switch window {
        case .three:
            return [
                TopicSuggestion(title: "Why bridges hum", hook: "Wind makes steel sing, and engineers tune it out on purpose.", domainTag: "Engineering"),
                TopicSuggestion(title: "The florin that priced Europe", hook: "One Florentine coin set exchange rates for two centuries.", domainTag: "History"),
                TopicSuggestion(title: "Why your knees predict rain", hook: "Barometric pressure moves joint fluid just enough to feel.", domainTag: "Biology"),
                TopicSuggestion(title: "Surge pricing before computers", hook: "Fish markets solved dynamic pricing a century before anyone else.", domainTag: "Economics"),
                TopicSuggestion(title: "Why choirs drift sharp", hook: "Group pitch rises predictably, and physics says it must.", domainTag: "Music", isWildcard: true),
            ]
        case .ten:
            return [
                TopicSuggestion(title: "How GPS corrects for relativity", hook: "Satellite clocks run fast; ignoring Einstein breaks navigation within hours.", domainTag: "Physics"),
                TopicSuggestion(title: "The invention of the weekend", hook: "Two days off is younger than the lightbulb.", domainTag: "History"),
                TopicSuggestion(title: "Why sourdough never dies", hook: "A starter is an ecosystem that defends itself.", domainTag: "Biology"),
                TopicSuggestion(title: "Container ships and the box", hook: "A standard steel box quietly rewrote the world economy.", domainTag: "Economics"),
                TopicSuggestion(title: "How typefaces steer trust", hook: "The same sentence reads as more true in some fonts.", domainTag: "Design", isWildcard: true),
            ]
        case .fifteen:
            return [
                TopicSuggestion(title: "The cholera map that made epidemiology", hook: "One well pump, one map, one stubborn doctor.", domainTag: "Medicine"),
                TopicSuggestion(title: "Why concrete cracks on schedule", hook: "Engineers plan the cracks before the pour.", domainTag: "Engineering"),
                TopicSuggestion(title: "Auctions that price the airwaves", hook: "Spectrum auctions are game theory with billions at stake.", domainTag: "Economics"),
                TopicSuggestion(title: "How whales rebuilt after whaling", hook: "Population genetics shows recovery routes nobody predicted.", domainTag: "Biology"),
                TopicSuggestion(title: "The grammar of film cuts", hook: "Your brain accepts jumps in space it never sees.", domainTag: "Film", isWildcard: true),
            ]
        case .thirty:
            return [
                TopicSuggestion(title: "How the metric system won", hook: "A revolution, a meridian survey, two centuries of persuasion.", domainTag: "History"),
                TopicSuggestion(title: "Reading a balance sheet properly", hook: "Three statements, one story, and where companies hide trouble.", domainTag: "Finance"),
                TopicSuggestion(title: "The immune system as army", hook: "Recruitment, memory, friendly fire: a tour of your defenses.", domainTag: "Biology"),
                TopicSuggestion(title: "Why planes are safe", hook: "Every crash rewrote a rule; the system learns better than people.", domainTag: "Engineering"),
                TopicSuggestion(title: "The mathematics of juggling", hook: "Siteswap notation turned a circus trick into number theory.", domainTag: "Mathematics", isWildcard: true),
            ]
        }
    }

    // MARK: - Lessons

    public func generateLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        try await pause(milliseconds: 700)
        return Self.fixtureLesson(topic: topic, window: window)
    }

    public func streamLesson(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        demand: ChapterDemand
    ) -> AsyncThrowingStream<LessonStreamEvent, Error> {
        let simulateLatency = self.simulateLatency
        let delay = chunkDelayMilliseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let lesson = Self.fixtureLesson(topic: topic, window: window)
                    let chapters = Self.fixtureChapterBodies(topic: topic, window: window)

                    continuation.yield(.metadata(lesson.metadata))

                    for (index, chapterBody) in chapters.enumerated() {
                        // Honour reader back-pressure exactly as the live
                        // provider does, so laziness is testable offline.
                        if index > 0 {
                            try await demand.waitUntilAllowed(chapter: index)
                        }
                        try Task.checkCancellation()
                        // Pass 1: draft the chapter. Not reader-facing.
                        for chunk in Self.chunks(of: chapterBody) {
                            if simulateLatency {
                                try await Task.sleep(nanoseconds: delay * 1_000_000)
                            }
                            continuation.yield(.draftDelta(chapter: index, text: chunk))
                        }
                        continuation.yield(.draftChapterFinished(chapter: index))

                        // Pass 2: revise the chapter. This is what the reader sees.
                        for chunk in Self.chunks(of: chapterBody) {
                            if simulateLatency {
                                try await Task.sleep(nanoseconds: delay * 1_000_000)
                            }
                            continuation.yield(.revisedDelta(chapter: index, text: chunk))
                        }
                        continuation.yield(.revisedChapterFinished(chapter: index))
                    }

                    continuation.yield(.finished(lesson))
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

    public func generateRecallQuestion(for lesson: Lesson) async throws -> RecallQuestion {
        try await pause(milliseconds: 300)
        return RecallQuestion(
            question: "What actually drove the effect described in \u{201C}\(lesson.title)\u{201D}?",
            answer: lesson.surprisingClaim,
            distractors: [
                "A difference of scale rather than of mechanism",
                "An artifact of how the measurement was taken",
                "The intuitive cause most people would name first",
            ],
            explanation: "The central claim of the piece: \(lesson.surprisingClaim)"
        )
    }

    public func generatePostLessonTest(for lesson: Lesson) async throws -> [RecallQuestion] {
        try await pause(milliseconds: 400)
        return [
            RecallQuestion(
                question: "What actually drove the effect described in \u{201C}\(lesson.title)\u{201D}?",
                answer: lesson.surprisingClaim,
                distractors: [
                    "A difference of scale rather than of mechanism",
                    "An artifact of how the measurement was taken",
                    "The intuitive cause most people would name first",
                ],
                explanation: "The central claim of the piece: \(lesson.surprisingClaim)"
            ),
            RecallQuestion(
                question: "Which domain does \u{201C}\(lesson.title)\u{201D} sit in?",
                answer: lesson.domainTag,
                distractors: [
                    "A neighbouring field that sounds similar but isn't it",
                    "The domain of the previous lesson in this format",
                    "A domain nobody would seriously propose",
                ],
                explanation: "The piece is tagged \(lesson.domainTag)."
            ),
            RecallQuestion(
                // Was answered by `lesson.subtitle`, which is built from the
                // window ("A 10-minute explainer") and therefore identical
                // for every lesson of that length -- the same
                // cross-contamination as the claim, one question along.
                question: "Which field does \u{201C}\(lesson.title)\u{201D} draw its example from?",
                answer: "\(lesson.domainTag), in the case of \(lesson.title.lowercased())",
                distractors: [
                    "A framing that inverts the actual claim",
                    "A generic framing that could fit almost any topic",
                    "A framing borrowed from a different subject entirely",
                ],
                explanation: "The piece's own subtitle: \(lesson.subtitle)"
            ),
        ]
    }

    public func goDeeper(
        from lesson: Lesson,
        angle: DeeperAngle,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) async throws -> Lesson {
        try await pause(milliseconds: 700)
        var deeper = Self.fixtureLesson(
            topic: TopicSuggestion(title: angle.text, hook: "", domainTag: lesson.domainTag),
            window: window
        )
        deeper.subtitle = "Going deeper on \u{201C}\(lesson.title)\u{201D}"
        return deeper
    }

    // MARK: - Fixture assembly

    public static func fixtureLesson(topic: TopicSuggestion, window: TimeWindow) -> Lesson {
        Lesson(
            title: topic.title,
            subtitle: "A \(window.minutes)-minute \(window.format.displayName.lowercased())",
            domainTag: topic.domainTag,
            bodyMarkdown: fixtureChapterBodies(topic: topic, window: window).joined(separator: "\n\n"),
            // Derived from the topic, not a fixed sentence.
            //
            // This was hardcoded to a Millennium Bridge claim regardless of
            // the topic, and it is the value the recall question and the
            // post-lesson test both use as the correct answer — so a lesson
            // titled "How GPS corrects for relativity" was quizzed on
            // pedestrians on a footbridge. Sample content is allowed to be
            // obviously sample; it is not allowed to be about a different
            // subject than the lesson it belongs to.
            surprisingClaim: surprisingClaim(for: topic),
            deeperAngles: [
                "The wider context around \(topic.title.lowercased())",
                "The specific mechanism behind \(topic.title.lowercased())",
                "The strongest case against the usual account of \(topic.title.lowercased())",
            ]
        )
    }

    /// A per-topic stand-in for the load-bearing claim. Deterministic, so the
    /// same topic always produces the same answer and a test can rely on it.
    static func surprisingClaim(for topic: TopicSuggestion) -> String {
        "The counterintuitive part of \(topic.title.lowercased()): the correction turns out to be the cause, not the cure."
    }

    /// One body per chapter. Single-chapter formats return one element.
    public static func fixtureChapterBodies(topic: TopicSuggestion, window: TimeWindow) -> [String] {
        let chapterCount = window.format.chapterCount
        let totalTarget = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
        let perChapterTarget = totalTarget / chapterCount

        return (0..<chapterCount).map { index in
            body(
                topic: topic,
                targetWords: perChapterTarget,
                maximumWords: window.chapterWordBudget.upperBound,
                sectioned: window.format != .oneThing,
                chapterNumber: chapterCount > 1 ? index + 1 : nil,
                paragraphOffset: index * 3,
                trailingReflection: window.format == .miniCourse
            )
        }
    }

    /// Builds prose of roughly `targetWords` words by cycling fixture
    /// paragraphs, adding section or chapter headings as the format requires.
    static func body(
        topic: TopicSuggestion,
        targetWords: Int,
        maximumWords: Int? = nil,
        sectioned: Bool,
        chapterNumber: Int?,
        paragraphOffset: Int,
        trailingReflection: Bool
    ) -> String {
        let fixtureParagraphs = Self.fixtureParagraphs(topic: topic)
        var parts: [String] = []
        var words = 0
        var paragraphIndex = paragraphOffset
        var sectionIndex = 0

        if let chapterNumber {
            let heading = "## Chapter \(chapterNumber): \(sectionTitles[(chapterNumber - 1) % sectionTitles.count])"
            parts.append(heading)
            words += heading.lessonWordCount
        }

        // Whole paragraphs only, so prose never ends mid-sentence -- which
        // means the fill has to stop *before* it would cross the ceiling
        // rather than after. Appending first and checking afterwards is what
        // pushed a 1,600-word chapter to 1,621.
        // The reflection prompt is appended after the fill loop, so its
        // words have to be reserved before it — otherwise the loop fills to
        // the ceiling and the reflection then pushes the chapter past it,
        // which is how 1,600 became 1,602.
        let reflection = "*Where in \(topic.title.lowercased()) have you already seen this and not noticed?*"
        let reservedForReflection = trailingReflection ? reflection.lessonWordCount : 0
        let ceiling = (maximumWords ?? Int.max) - reservedForReflection
        while words < targetWords {
            // A section break every fourth paragraph for sectioned, unchaptered
            // formats.
            if sectioned, chapterNumber == nil, paragraphIndex % 4 == 0 {
                let heading = "## \(sectionTitles[sectionIndex % sectionTitles.count])"
                parts.append(heading)
                words += heading.lessonWordCount
                sectionIndex += 1
            }
            let paragraph = fixtureParagraphs[paragraphIndex % fixtureParagraphs.count]
            let paragraphWords = paragraph.lessonWordCount
            if words + paragraphWords > ceiling { break }
            parts.append(paragraph)
            words += paragraphWords
            paragraphIndex += 1
        }

        if trailingReflection {
            parts.append(reflection)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Splits text into streamable chunks at paragraph boundaries, preserving
    /// the separators so reassembly is exact.
    static func chunks(of text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        return paragraphs.enumerated().map { index, paragraph in
            index == paragraphs.count - 1 ? paragraph : paragraph + "\n\n"
        }
    }

    static let sectionTitles = [
        "The day someone measured it",
        "What is actually moving",
        "Why the fix runs backwards",
        "The bargain underneath",
        "What it changed",
        "Seeing it everywhere",
    ]

    /// Sample prose, parameterised by topic.
    ///
    /// These used to be eight fixed paragraphs about the Millennium Bridge,
    /// rendered under whatever title the reader had picked — so a lesson
    /// called "How GPS corrects for relativity" was several hundred words
    /// about pedestrians on a footbridge. Filler is fine; filler about a
    /// different subject is what made the offline build look broken.
    ///
    /// Deliberately preserved from the originals: a digit in the opening
    /// sentence (so the definition-opener check doesn't fire), hard variation
    /// in sentence length, no banned vocabulary, and a closing paragraph that
    /// shares little wording with the opening. `LessonQualityCheck` asserts
    /// all four against every fixture.
    static func fixtureParagraphs(topic: TopicSuggestion) -> [String] {
        let subject = topic.title.lowercased()
        let field = topic.domainTag.lowercased()
        return [
            "In 1954 someone finally measured it, and the number came back wrong twice before anyone believed it. \(subject.prefix(1).uppercased() + subject.dropFirst()) had three competing explanations at the time. Two were tidy. The tidy ones were the ones that failed.",
            "Here is the mechanism. A small change feeds back into the thing that produced it, and the loop closes. Each correction makes the next correction larger. Run that for long enough and the behaviour everyone was trying to damp is the behaviour they were accidentally driving. This is the part of \(subject) that gets left out of the summary.",
            "The same shape turns up elsewhere in \(field). A system has some state it prefers. A push arrives at the rate that state already likes. The pushes stop cancelling and start adding, and a quantity nobody was watching climbs until somebody notices.",
            "The fix is where intuition breaks. You would expect the answer to be more: more rigidity, more control, more correction. Often it is less. Give the system somewhere to put the energy and it stops accumulating it. The counterweight moves so the structure does not have to.",
            "So the repair was not the expensive one. It was a handful of components, a small fraction of the total cost, doing their work invisibly to everyone who benefits from them.",
            "There is a bargain hidden in that. Something rigid enough never to move at all would be ruinously expensive and, under a real shock, brittle. The working answer is to accept motion and manage it, keeping it under the threshold where anyone files a complaint.",
            "Once you know the pattern you find it everywhere. The glass that rings at one pitch. The trolley that wobbles at exactly one speed. The shudder at 110 and not at 100. Each is a system with a preference meeting a push that happens to match it.",
            "Next time \(subject) comes up, the interesting question is not what the effect is. It is what is quietly absorbing the energy, and what would happen to everything around it if that thing stopped.",
        ]
    }

    // MARK: - Helpers

    private func pause(milliseconds: UInt64) async throws {
        guard simulateLatency else { return }
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
