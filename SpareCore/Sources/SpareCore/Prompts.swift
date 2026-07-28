import Foundation

/// Prompt construction. Kept in core so the exact wording is unit-testable
/// and reviewable without opening the networking layer.
public enum Prompts {

    // MARK: - Shared

    /// Words and phrases that must never appear in generated prose. Used both
    /// in the prompt and by `LessonQualityCheck` to verify the revision pass.
    public static let bannedPhrases: [String] = [
        "delve",
        "moreover",
        "furthermore",
        "it's important to note",
        "it is important to note",
        "in today's world",
        "at its core",
        "unlock",
        "harness",
        "leverage",
        "landscape",
        "tapestry",
        "realm",
        "navigate the complexities",
        "game-changer",
        "game changer",
        "the fascinating world of",
        "let's dive in",
        "lets dive in",
        "hopefully this helps",
    ]

    static func readerContext(_ profile: ProfileSnapshot) -> String {
        let interests = profile.interests.isEmpty ? "unstated" : profile.interests.joined(separator: ", ")
        let work = profile.work.isEmpty ? "unstated" : profile.work
        let gaps = profile.curiosityGaps.isEmpty ? "unstated" : profile.curiosityGaps.joined(separator: "; ")
        return """
        - Works in: \(work)
        - Interested in: \(interests)
        - Has said they don't really understand: \(gaps)
        - Preferred register: \(profile.complexity.promptDescription)
        """
    }

    static func budgetPhrase(_ range: ClosedRange<Int>) -> String {
        "\(range.lowerBound)–\(range.upperBound)"
    }

    // MARK: - Lesson (pass 1)

    public static func lessonSystemPrompt(
        topic: String,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) -> String {
        """
        You write for an app that gives curious adults one genuinely good thing to
        learn in a fixed window of time. Your reader is smart, has no background in
        this topic, and has \(window.minutes) minutes.

        Write a \(window.format.displayName) on: \(topic)

        Structure: \(window.format.structureBrief)

        Target length: \(budgetPhrase(window.wordBudget)) words. Treat this as a real constraint.

        Reader context — use it to pick examples and calibrate depth, never mention it:
        \(readerContext(profile))

        HOW TO WRITE

        Open with something concrete. A number, a date, a person, a specific scene,
        a thing that happened. Never open with a definition, never with "X is a
        fascinating topic," never with the phrase "imagine that."

        Every abstract claim gets a concrete instance within two sentences. If you
        can't produce one, the claim isn't earned — cut it.

        Include at least one thing the reader will want to repeat to someone else.
        Something true, checkable, and genuinely counterintuitive. Not a fun-fact
        garnish — it should be load-bearing to the explanation.

        Vary sentence length hard. Long, clause-heavy sentences next to short ones.
        Fragments are allowed.

        Prose by default. Use a list only when the content is genuinely enumerable —
        four named types of something, five steps in an order. A list of concepts is
        prose that gave up.

        End by changing how the reader sees something they already encounter. Not a
        summary. Not "in conclusion." Not a restatement of the opening.

        NEVER USE
        delve, moreover, furthermore, "it's important to note", "in today's world",
        "at its core", unlock, harness, leverage (as a verb), landscape, tapestry,
        realm, "navigate the complexities", "game-changer", "the fascinating world
        of", "let's dive in", "hopefully this helps".

        NEVER DO
        - Congratulate the reader or comment on the topic's quality.
        - Stack hedges ("some argue it may possibly").
        - Write a closing paragraph that restates the piece.
        - Use second person more than a few times.
        - Add emoji.
        - Pad to hit the word count. Under-budget and tight beats on-budget and thin.

        FACTUAL DISCIPLINE
        Only state what you're confident is true. Where genuine scholarly or
        scientific disagreement exists, say so in one clause and move on — don't
        turn it into a both-sides paragraph. Never invent a statistic, a study, a
        date, or a quotation. If you find yourself reaching for a specific number
        you're not sure of, write the claim without the number instead.
        """
    }

    public static func lessonUserPrompt(topic: TopicSuggestion) -> String {
        var lines = ["Topic: \(topic.title)"]
        if !topic.hook.isEmpty {
            lines.append("Angle: \(topic.hook)")
        }
        if !topic.domainTag.isEmpty {
            lines.append("Domain: \(topic.domainTag)")
        }
        lines.append("Write the lesson.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Revision (pass 2)

    public static func revisionSystemPrompt(window: TimeWindow) -> String {
        """
        Here is a draft lesson. Edit it. Return the same schema, nothing else.

        Check every item:
        1. Does the first sentence contain something concrete and specific? If not,
           rewrite the opening.
        2. Find every abstract claim without a concrete instance nearby. Add one or
           cut the claim.
        3. Delete every sentence that only restates a previous sentence.
        4. Find the banned words and phrases. Remove them.
        5. Is there at least one genuinely surprising, checkable claim? If not, the
           lesson is boring — find one and work it in.
        6. Does the last paragraph summarize? If so, replace it with something that
           changes how the reader sees a thing they already encounter.
        7. Are sentence lengths varied, or is everything 15–25 words? Break the rhythm.
        8. Any list that should be prose? Convert it.
        9. Any invented-sounding statistic or study? Remove the specific figure.
        10. Is it within \(budgetPhrase(window.wordBudget)) words? Cut rather than pad.

        Do not explain your edits. Return the revised lesson.
        """
    }

    /// The revision pass streams, so the reader is waiting on its opening words.
    /// Front-loading matters: it must not reorder the piece.
    public static func revisionUserPrompt(draftJSON: String) -> String {
        """
        \(draftJSON)

        Revise in place, front to back. Do not reorder sections or chapters: the
        reader is already being shown your output as it arrives, so the opening
        must be final when you write it.
        """
    }

    // MARK: - Chapters (45-minute mini-course)

    public static func chapterSystemPrompt(
        topic: String,
        window: TimeWindow,
        profile: ProfileSnapshot,
        chapterNumber: Int,
        chapterCount: Int,
        previousChapterSummaries: [String]
    ) -> String {
        let priorContext: String
        if previousChapterSummaries.isEmpty {
            priorContext = "This is the first chapter. Establish the concrete hook the rest will build on."
        } else {
            let summaries = previousChapterSummaries
                .enumerated()
                .map { "Chapter \($0.offset + 1): \($0.element)" }
                .joined(separator: "\n")
            priorContext = """
            Chapters already written — build on them, do not repeat them:
            \(summaries)
            """
        }

        return """
        You write for an app that gives curious adults one genuinely good thing to
        learn in a fixed window of time. Your reader is smart, has no background in
        this topic, and has \(window.minutes) minutes for the whole course.

        Write chapter \(chapterNumber) of \(chapterCount) of a mini-course on: \(topic)

        Target length for this chapter: \(budgetPhrase(window.chapterWordBudget)) words.
        End the chapter with a single reflection prompt, in italics.

        \(priorContext)

        Reader context — use it to pick examples and calibrate depth, never mention it:
        \(readerContext(profile))

        \(sharedCraftRules)
        """
    }

    /// The craft rules shared between the whole-lesson and per-chapter prompts.
    static let sharedCraftRules = """
        HOW TO WRITE

        Open with something concrete. A number, a date, a person, a specific scene,
        a thing that happened. Never open with a definition, never with "X is a
        fascinating topic," never with the phrase "imagine that."

        Every abstract claim gets a concrete instance within two sentences. If you
        can't produce one, the claim isn't earned — cut it.

        Include at least one thing the reader will want to repeat to someone else.
        Something true, checkable, and genuinely counterintuitive.

        Vary sentence length hard. Fragments are allowed.

        Prose by default. A list of concepts is prose that gave up.

        NEVER USE
        delve, moreover, furthermore, "it's important to note", "in today's world",
        "at its core", unlock, harness, leverage (as a verb), landscape, tapestry,
        realm, "navigate the complexities", "game-changer", "the fascinating world
        of", "let's dive in", "hopefully this helps".

        NEVER DO
        - Congratulate the reader or comment on the topic's quality.
        - Stack hedges. Add emoji. Use second person more than a few times.
        - Pad to hit the word count. Under-budget and tight beats on-budget and thin.

        FACTUAL DISCIPLINE
        Only state what you're confident is true. Never invent a statistic, a study,
        a date, or a quotation. If you're reaching for a number you're unsure of,
        write the claim without it.
        """

    // MARK: - Topic suggestions

    public static func suggestionSystemPrompt(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) -> String {
        let recent = history
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(SuggestionValidator.historyWindow)
            .map { "- \($0.title) [\($0.topicTag)]" }
            .joined(separator: "\n")
        let exclusions = recent.isEmpty ? "(nothing read yet)" : recent

        return """
        You suggest topics for an app where the reader chooses a length of time,
        not a subject. They have \(window.minutes) minutes and will get a
        \(window.format.displayName).

        Return exactly 5 suggestions.

        RULES
        - Every suggestion must genuinely fit \(window.minutes) minutes. "The history
          of the Ottoman Empire" is not a 3-minute topic. "Why Ottoman tax records
          are better than European ones" is.
        - The 5 must span at least 3 different domains.
        - Exactly one is a deliberate wildcard from outside the reader's stated
          interests. Mark it with isWildcard: true. This is what stops the app
          collapsing into a filter bubble.
        - At least one should connect to a stated curiosity gap.
        - Exclude anything semantically close to the lessons listed below.
          Adjacent-but-new is fine; repetition is not.
        - Title: 7 words maximum. Hook: 14 words maximum, one line.
        - Both written to make someone curious without clickbait. "You won't
          believe" is an instant fail. No question-mark bait, no withheld payoff.

        Reader context:
        \(readerContext(profile))

        Already read — do not repeat:
        \(exclusions)
        """
    }

    public static func suggestionUserPrompt(window: TimeWindow) -> String {
        "Suggest 5 topics for \(window.minutes) minutes."
    }

    // MARK: - Recall

    public static func recallSystemPrompt() -> String {
        """
        Write one recall question about the lesson below, to be asked a day or
        more later.

        - Test the central idea, not a trivia detail. If someone could answer it
          from the title alone, it is the wrong question.
        - Four options total: one correct answer and exactly 3 distractors.
        - Each distractor must be something a person who half-read the lesson
          would plausibly pick. No joke options, no obviously wrong options.
        - All four options should be about the same length and specificity.
        - Add one sentence explaining why the answer is right.
        - Do not mention "the lesson" or "the article" in the question. Ask about
          the world, not about the text.
        """
    }

    public static func recallUserPrompt(lesson: Lesson) -> String {
        """
        Title: \(lesson.title)
        Central claim: \(lesson.surprisingClaim)

        \(lesson.bodyMarkdown)
        """
    }

    // MARK: - Go deeper

    public static func goDeeperSystemPrompt(
        window: TimeWindow,
        profile: ProfileSnapshot,
        parentTitle: String,
        angle: DeeperAngle
    ) -> String {
        """
        The reader has just finished a lesson called "\(parentTitle)" and chose to
        go deeper on this angle: \(angle.text)

        Write a \(window.format.displayName) on that angle. They have
        \(window.minutes) minutes. Target \(budgetPhrase(window.wordBudget)) words.

        Assume they remember the previous lesson. Do not re-explain its basics or
        re-use its opening example. Go further, not wider.

        Structure: \(window.format.structureBrief)

        Reader context — use it to pick examples, never mention it:
        \(readerContext(profile))

        \(sharedCraftRules)
        """
    }
}
