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
        case .fortyFive:
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
        profile: ProfileSnapshot
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
            surprisingClaim: "The Millennium Bridge closed two days after opening because pedestrians synchronised their steps to its sway, so each correction fed the wobble it was correcting.",
            deeperAngles: [
                "The broader physics of resonance in built structures",
                "How a tuned mass damper actually works",
                "The case against over-damping: when flexibility is safer",
            ]
        )
    }

    /// One body per chapter. Single-chapter formats return one element.
    public static func fixtureChapterBodies(topic: TopicSuggestion, window: TimeWindow) -> [String] {
        let chapterCount = window.format.chapterCount
        let totalTarget = (window.wordBudget.lowerBound + window.wordBudget.upperBound) / 2
        let perChapterTarget = totalTarget / chapterCount

        return (0..<chapterCount).map { index in
            body(
                targetWords: perChapterTarget,
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
        targetWords: Int,
        sectioned: Bool,
        chapterNumber: Int?,
        paragraphOffset: Int,
        trailingReflection: Bool
    ) -> String {
        var parts: [String] = []
        var words = 0
        var paragraphIndex = paragraphOffset
        var sectionIndex = 0

        if let chapterNumber {
            let heading = "## Chapter \(chapterNumber): \(sectionTitles[(chapterNumber - 1) % sectionTitles.count])"
            parts.append(heading)
            words += heading.lessonWordCount
        }

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
            parts.append(paragraph)
            words += paragraph.lessonWordCount
            paragraphIndex += 1
        }

        if trailingReflection {
            let reflection = "*Where on your own daily route do you cross something engineered to move?*"
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
        "The day it happened",
        "What the wind is doing",
        "Why the fix is counterintuitive",
        "The engineers' bargain",
        "What it changed",
        "Seeing it everywhere",
    ]

    static let fixtureParagraphs: [String] = [
        "On June 10, 2000, the Millennium Bridge opened across the Thames. Within hours it was swaying hard enough that people grabbed the rails. Two days later it closed, and stayed closed for almost two years. The engineers had run every simulation. What they had not simulated was people.",
        "Here is the mechanism. When a walkway moves sideways, even slightly, you widen your stance and time your steps to the motion. So does everyone near you. A crowd that arrived walking at random leaves walking in step, and a thousand synchronised footfalls push the deck at exactly its natural frequency. The correction is the cause.",
        "Steel sings for a related reason. Wind sheds alternating vortices off a cable or a deck edge, and each vortex gives a small tug. When the tug rate matches a frequency the structure already prefers, the tugs add instead of cancelling. Engineers call it lock-in. Residents near a humming bridge call the council.",
        "The counterintuitive part is the fix. You might expect stiffer, heavier, stronger. Often the answer is the opposite: add something floppy. A tuned mass damper is a weight on a spring, set to the structure's own frequency, that swallows energy by swinging out of phase. The building sways, the weight sways against it, and the sum is stillness.",
        "So the repair was not new towers or thicker cables. It was thirty-seven fluid dampers and twenty-six tuned mass dampers bolted quietly under the deck, a few percent of the bridge's cost, invisible to everyone walking over them.",
        "There is a bargain hidden here. A structure rigid enough never to oscillate would be monstrously expensive and, in an earthquake, brittle. Engineers accept motion and then manage it. Every tall building you have been in moves constantly; it is simply kept below the threshold where your inner ear files a complaint.",
        "Once you know the pattern you find it everywhere. The wine glass that rings at one pitch. The shopping trolley that wobbles at exactly one speed. The shudder in a car at 110 and not at 100. Each is a system with a preferred frequency meeting a push that happens to match it.",
        "Next time a footbridge feels alive under you, it is. Not failing. Negotiating. Somewhere under the deck a mass you will never see is swinging in precise opposition to your steps, spending your energy so the steel does not have to.",
    ]

    // MARK: - Helpers

    private func pause(milliseconds: UInt64) async throws {
        guard simulateLatency else { return }
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
