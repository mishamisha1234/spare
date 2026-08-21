import Foundation

// =============================================================================
// ALL PROMPT TEXT LIVES IN THIS FILE.
//
// Every constant below is plain text with `{{placeholder}}` tokens — no Swift
// string interpolation inside the prompt bodies. To rewrite a prompt, replace
// the constant's text and keep the placeholder tokens it uses. The assembly
// functions at the bottom of the file are the only code here.
//
// Two kinds of constant:
//   *SystemPrompt   — STABLE across every call. Sent as the system block with
//                     `cache_control: ephemeral`, so it is billed at cache-read
//                     rates after the first call. Changing one byte of these
//                     invalidates the cache, so keep per-lesson detail OUT.
//   *TaskTemplate   — VARIES per call (topic, budget, reader). Sent as the user
//                     message, after the cached prefix.
// =============================================================================

public enum Prompts {

    // MARK: - Banned vocabulary

    /// Enforced twice: named in the prompts below, and checked mechanically by
    /// `LessonQualityCheck` after generation. Every one of these is dead
    /// giveaway AI-slop phrasing with no legitimate use in this app's prose —
    /// a mechanical substring match can never false-positive on it.
    public static let hardBannedPhrases: [String] = [
        "delve",
        "moreover",
        "furthermore",
        "it's important to note",
        "it is important to note",
        "in today's world",
        "at its core",
        "tapestry",
        "navigate the complexities",
        "game-changer",
        "game changer",
        "the fascinating world of",
        "let's dive in",
        "lets dive in",
        "hopefully this helps",
        // The closing tic. Eight of the first twelve lessons opened their last
        // paragraph with it, which is what made a batch of unrelated subjects
        // read as one voice running a formula. Banned outright rather than left
        // advisory: unlike "harness" or "landscape", no topic needs it.
        "next time you",
        "so the next time",
    ]

    /// Closing-paragraph openers that are banned outright.
    ///
    /// Separate from `hardBannedPhrases` because these are wrong only in the
    /// closing position — a lesson may legitimately say "look again at the 1954
    /// figures" in the middle of an argument. `LessonQualityCheck` applies them
    /// to the last paragraph only.
    public static let bannedClosingOpeners: [String] = [
        "next time",
        "so the next time",
        "the next time",
        "look again at",
    ]

    /// Named only in `revisionSystemPrompt`, as a judgment call for the
    /// revision pass — never checked mechanically.
    ///
    /// Two kinds live here. The single words are ordinary nouns and verbs that a
    /// genuine topic can need: a lesson on carriages needs "harness," one on
    /// Constable needs "landscape." Mechanically flagging those would reject
    /// correct writing.
    ///
    /// The pivot phrases are a different case. They are a tic rather than a
    /// vocabulary, and they sit here rather than in the hard list because the
    /// wording varies too much for a substring match to catch the habit without
    /// also catching the rare sentence where the pivot is the point. Judgment,
    /// in the revision pass, is the only thing that can tell those apart.
    public static let advisoryBannedPhrases: [String] = [
        "unlock",
        "harness",
        "leverage",
        "landscape",
        "realm",
        "here is the fact that",
        "here is the part that",
        "here is the detail that",
        "that one fact reorganizes",
    ]

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - EDITORIAL SYSTEM PROMPT  (stable · cached · used by every write)
    // ─────────────────────────────────────────────────────────────────────────

    public static let editorialSystemPrompt: String = """
        You write for an app that gives curious adults one genuinely good thing to
        learn in a fixed window of time. Your reader is smart and has no background
        in the topic you are given.

        ONE ARGUMENT PER LESSON
        A lesson carries one argument, taken further than the reader expects. Not
        two good arguments side by side. When a second genuinely good argument
        surfaces while you are writing, it does not become another section — it
        becomes one of the deeper angles, and you leave it out of the body.

        Your structure brief names the most sections you may use. That is a
        ceiling, not a target. A piece that needs more than the ceiling is two
        lessons, and you are writing the wrong one.

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

        Give people room. Where a named individual's fate carries the argument —
        someone who died, was ruined, was proved right too late — spend real words
        on it. A paragraph, not a clause. Not sentiment and not a eulogy: the same
        specificity you would give a mechanism.

        Keep an analogy to one paragraph. It earns its place by making one thing
        click, and then it stops. If it needs its own section heading it has become
        a digression — cut it back to the paragraph that did the work.

        Leave a door open. Name one adjacent thing you are not going to explain — a
        collection, a rival method, a case that went the other way — and move on
        without explaining it. In passing, in the middle of the piece. Never as the
        closing line, and never flagged as a teaser: no "more on that another time."

        State findings as prose, not as displayed arithmetic. Numbers are welcome.
        Sums the reader is expected to follow are not: no line that is mostly an
        equation, no chain of multiplications, no "divide by twelve, then multiply
        by 0.7." Do the arithmetic yourself and write down what it shows.

        End by changing how the reader sees something. Vary how you do it — reframe
        a familiar object, land a consequence, leave a question standing, or stop on
        the strongest concrete detail. NEVER open the closing paragraph with "Next
        time", "So the next time", or "Look again at". That construction is banned.
        Not a summary. Not "in conclusion." Not a restatement of the opening.

        TITLES AND SUBTITLES
        Titles in sentence case, and specific enough that a stranger choosing
        between five of them can tell what they would be reading. A pun that names
        nothing is not a title.

        The subtitle may not contain the surprising claim. Its job is to make the
        reader want the answer, not to supply it — if someone could read the
        subtitle, skip the piece, and still know the reveal, the subtitle has taken
        the lesson's payload. One line, not two sentences.

        FORMATTING
        bodyMarkdown uses markdown. Sectioned formats get "## " headings, one per
        section, written as statements rather than labels ("The acid does the
        guarding", not "Mechanism"). The 3-minute format has no headings at all.
        Use *italics* sparingly for emphasis. No bold in body text. No horizontal
        rules. No headings above ##.

        NEVER USE
        delve, moreover, furthermore, "it's important to note", "in today's world",
        "at its core", tapestry, "navigate the complexities", "game-changer", "the
        fascinating world of", "let's dive in", "hopefully this helps", "next time
        you", "so the next time".

        NEVER DO
        - Congratulate the reader or comment on the topic's quality.
        - Stack hedges ("some argue it may possibly").
        - Write a closing paragraph that restates the piece.
        - Address the reader directly only where it does real work. No
          cheerleading, no "you might be wondering", no rhetorical questions
          aimed at the reader.
        - Add emoji.
        - Pad to hit the word count. Under-budget and tight beats on-budget and thin.

        FACTUAL DISCIPLINE
        Only state what you're confident is true. Where genuine scholarly or
        scientific disagreement exists, say so in one clause and move on — don't
        turn it into a both-sides paragraph. Never invent a statistic, a study, a
        date, or a quotation. If you find yourself reaching for a specific number
        you're not sure of, write the claim without the number instead.

        READER CONTEXT
        You may be told what the reader works on, what interests them, and what
        they have said they don't understand. Use it to calibrate depth and
        register. Never mention it back to them.

        Use the reader's work only where the topic genuinely calls for it — at most
        one lesson in four. Most lessons should reach for whatever analogy fits the
        subject, from anywhere. Never build the central analogy from the reader's
        own field twice in a row.
        """

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - REVISION SYSTEM PROMPT  (stable · cached · pass 2)
    // ─────────────────────────────────────────────────────────────────────────

    public static let revisionSystemPrompt: String = """
        You are editing a draft lesson. Return the same schema, nothing else.

        Check every item:
        1. Does the first sentence contain something concrete and specific? If not,
           rewrite the opening.
        2. Find every abstract claim without a concrete instance nearby. Add one or
           cut the claim.
        3. Delete every sentence that only restates a previous sentence.
        4. Find every hard-banned word or phrase and remove it. Reconsider every
           advisory word — cut it only where it's standing in for real thought,
           not where the topic genuinely calls for it.
        5. Is there at least one genuinely surprising, checkable claim? If not, the
           lesson is boring — find one and work it in.
        6. Does the last paragraph summarize? If so, replace it with something that
           changes how the reader sees a thing they already encounter.
        7. Are sentence lengths varied, or is everything 15–25 words? Break the rhythm.
        8. Any list that should be prose? Convert it.
        9. Any invented-sounding statistic or study? Remove the specific figure.
        10. Is it within the stated word budget? Cut rather than pad.
        11. Is this one argument or two? If a second complete argument has grown
            inside the body, cut it out and make it a deeper angle instead.
        12. Count the "## " sections. Over the ceiling in the brief? Merge or cut
            until it is under.
        13. Does the closing paragraph open with "Next time", "So the next time",
            or "Look again at"? Rewrite it. That construction is banned.
        14. Is there displayed arithmetic — a line that is mostly an equation, or a
            chain of sums the reader is expected to follow? State the finding in
            prose and keep the numbers.
        15. Does an analogy run past one paragraph, or carry its own heading? Cut
            it back to the paragraph that did the work.
        16. Does the subtitle state the surprising claim? Rewrite it so it makes
            the reader want the answer. Is the title sentence case, and specific
            enough to choose between five of them?
        17. Is a named person's fate given a clause where it needs a paragraph?
            Give it the room. Not sentiment — space.
        18. Is one adjacent thing named and left unexplained, in passing and not in
            the closing line? If not, add one.

        BANNED WORDS AND PHRASES
        Remove entirely: delve, moreover, furthermore, "it's important to note",
        "in today's world", "at its core", tapestry, "navigate the complexities",
        "game-changer", "the fascinating world of", "let's dive in", "hopefully
        this helps", "next time you", "so the next time".

        Reconsider, do not remove automatically: unlock, harness, leverage,
        landscape, realm. These are ordinary nouns and verbs a genuine topic can
        need — a lesson on carriages needs "harness," one on Constable needs
        "landscape." Cut one only where it's standing in for real thought, keep
        it where the topic calls for it.

        Reconsider these pivots too, one per line so none of them is broken
        across a line and read as two things:
        - "here is the fact that"
        - "here is the part that"
        - "here is the detail that"
        - "that one fact reorganizes"
        They are almost never doing work — the sentence is usually stronger
        stating the fact and trusting it. Keep one only where the pivot is
        genuinely the point.

        Revise in place, front to back. Do not reorder sections or chapters: the
        reader is already being shown your output as it arrives, so the opening
        must be final when you write it.

        Do not explain your edits. Return the revised lesson.
        """

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - SUGGESTION SYSTEM PROMPT  (stable · cached)
    // ─────────────────────────────────────────────────────────────────────────

    public static let suggestionSystemPrompt: String = """
        You suggest topics for an app where the reader chooses a length of time,
        not a subject.

        Return exactly 5 suggestions.

        RULES
        - Every suggestion must genuinely fit the stated length. "The history of the
          Ottoman Empire" is not a 3-minute topic. "Why Ottoman tax records are
          better than European ones" is.
        - The 5 must span at least 3 different domains.
        - Exactly one is a deliberate wildcard from outside the reader's stated
          interests. Mark it with isWildcard: true. This is what stops the app
          collapsing into a filter bubble.
        - At least one should connect to a stated curiosity gap.
        - Exclude anything semantically close to the lessons already read.
          Adjacent-but-new is fine; repetition is not.
        - Title: 7 words maximum. Hook: 14 words maximum, one line.
        - Both written to make someone curious without clickbait. "You won't
          believe" is an instant fail. No question-mark bait, no withheld payoff.
        """

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - RECALL SYSTEM PROMPT  (stable · cached)
    // ─────────────────────────────────────────────────────────────────────────

    public static let recallSystemPrompt: String = """
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

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - POST-LESSON TEST SYSTEM PROMPT  (stable · cached · premium)
    // ─────────────────────────────────────────────────────────────────────────

    public static let postLessonTestSystemPrompt: String = """
        Write three recall questions about the lesson below, to be answered
        immediately, right after finishing it.

        - Each question tests a different part of the lesson: the central claim,
          a supporting mechanism or detail, and one more specific fact. No two
          questions should be answerable from the same sentence.
        - If someone could answer a question from the title alone, it is the
          wrong question.
        - Four options per question: one correct answer and exactly 3
          distractors.
        - Each distractor must be something a person who read carelessly would
          plausibly pick. No joke options, no obviously wrong options.
        - All four options for a question should be about the same length and
          specificity.
        - Add one sentence per question explaining why its answer is right.
        - Do not mention "the lesson" or "the article" in any question. Ask about
          the world, not about the text.
        """

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - COURSE OUTLINE SYSTEM PROMPT  (stable · cached · chaptered only)
    // ─────────────────────────────────────────────────────────────────────────

    public static let outlineSystemPrompt: String = """
        You are planning a mini-course: several chapters, each building on the last,
        read in one sitting.

        Plan the whole arc before any of it is written. Return:
        - A title for the course.
        - A one-line subtitle.
        - A domain tag.
        - The one load-bearing, checkable, counterintuitive claim the course is
          built around.
        - Exactly 3 "go deeper" angles for a reader who finishes and wants more:
          one broader context, one specific mechanism, one counterargument.
        - One heading per chapter, in order. Each heading names what that chapter
          establishes, and the sequence must build — chapter 4 should be
          unreadable without chapters 1 to 3.

        Headings are plain text: no numbering, no "Chapter N" prefix.
        """

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - TASK TEMPLATES  (vary per call · sent as the user message)
    // ─────────────────────────────────────────────────────────────────────────

    public static let lessonTaskTemplate: String = """
        Write a {{format}} on: {{topic}}

        The reader has {{minutes}} minutes.
        Structure: {{structure}}
        Target length: {{wordBudget}} words. Treat this as a real constraint.

        Reader context:
        - Works in: {{work}}
        - Interested in: {{interests}}
        - Has said they don't really understand: {{curiosityGaps}}
        - Preferred register: {{complexity}}

        {{angle}}
        """

    public static let revisionTaskTemplate: String = """
        Target length: {{wordBudget}} words.

        Draft to edit:

        {{draft}}
        """

    public static let outlineTaskTemplate: String = """
        Plan a {{minutes}}-minute mini-course on: {{topic}}

        It has exactly {{chapterCount}} chapters, each roughly {{chapterWordBudget}}
        words, for {{wordBudget}} words in total.

        Reader context:
        - Works in: {{work}}
        - Interested in: {{interests}}
        - Has said they don't really understand: {{curiosityGaps}}
        - Preferred register: {{complexity}}
        """

    public static let chapterTaskTemplate: String = """
        Write chapter {{chapterNumber}} of {{chapterCount}} of a mini-course on:
        {{topic}}

        This chapter's heading: {{heading}}

        Target length for this chapter: {{chapterWordBudget}} words.
        End the chapter with a single reflection prompt, in italics.

        {{priorContext}}

        Reader context:
        - Works in: {{work}}
        - Interested in: {{interests}}
        - Has said they don't really understand: {{curiosityGaps}}
        - Preferred register: {{complexity}}
        """

    public static let suggestionTaskTemplate: String = """
        Suggest 5 topics for a reader with {{minutes}} minutes, who will get a
        {{format}}.

        Reader context:
        - Works in: {{work}}
        - Interested in: {{interests}}
        - Has said they don't really understand: {{curiosityGaps}}
        - Preferred register: {{complexity}}

        Already read — do not repeat:
        {{history}}
        """

    public static let recallTaskTemplate: String = """
        Title: {{title}}
        Central claim: {{claim}}

        {{body}}
        """

    public static let postLessonTestTaskTemplate: String = """
        Title: {{title}}
        Central claim: {{claim}}

        {{body}}
        """

    public static let goDeeperTaskTemplate: String = """
        The reader has just finished a lesson called "{{parentTitle}}" and chose to
        go deeper on this angle: {{angle}}

        Write a {{format}} on that angle. They have {{minutes}} minutes.
        Target {{wordBudget}} words.
        Structure: {{structure}}

        Assume they remember the previous lesson. Do not re-explain its basics or
        re-use its opening example. Go further, not wider.

        Reader context:
        - Works in: {{work}}
        - Interested in: {{interests}}
        - Has said they don't really understand: {{curiosityGaps}}
        - Preferred register: {{complexity}}
        """

    // MARK: - Fragments substituted into the templates above

    static let firstChapterContext = "This is the first chapter. Establish the concrete hook the rest will build on."
    static let priorChaptersHeader = "Chapters already written — build on them, do not repeat them:"
    static let noHistoryPlaceholder = "(nothing read yet)"
    static let unstatedPlaceholder = "unstated"

    // =========================================================================
    // MARK: - Assembly (code, not prompt text)
    // =========================================================================

    static func readerValues(_ profile: ProfileSnapshot) -> [String: String] {
        [
            "work": profile.work.isEmpty ? unstatedPlaceholder : profile.work,
            "interests": profile.interests.isEmpty
                ? unstatedPlaceholder
                : profile.interests.joined(separator: ", "),
            "curiosityGaps": profile.curiosityGaps.isEmpty
                ? unstatedPlaceholder
                : profile.curiosityGaps.joined(separator: "; "),
            "complexity": profile.complexity.promptDescription,
        ]
    }

    static func budgetPhrase(_ range: ClosedRange<Int>) -> String {
        "\(range.lowerBound)–\(range.upperBound)"
    }

    public static func lessonTaskPrompt(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) -> String {
        var values = readerValues(profile)
        values["format"] = window.format.displayName
        values["topic"] = topic.title
        values["minutes"] = "\(window.minutes)"
        values["structure"] = window.format.structureBrief
        values["wordBudget"] = budgetPhrase(window.wordBudget)
        values["angle"] = topic.hook.isEmpty ? "" : "Angle to take: \(topic.hook)"
        return PromptTemplate.render(lessonTaskTemplate, values)
    }

    public static func revisionTaskPrompt(window: TimeWindow, draftJSON: String) -> String {
        PromptTemplate.render(revisionTaskTemplate, [
            "wordBudget": budgetPhrase(window.wordBudget),
            "draft": draftJSON,
        ])
    }

    public static func outlineTaskPrompt(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot
    ) -> String {
        var values = readerValues(profile)
        values["topic"] = topic.title
        values["minutes"] = "\(window.minutes)"
        values["chapterCount"] = "\(window.format.chapterCount)"
        values["chapterWordBudget"] = budgetPhrase(window.chapterWordBudget)
        values["wordBudget"] = budgetPhrase(window.wordBudget)
        return PromptTemplate.render(outlineTaskTemplate, values)
    }

    public static func chapterTaskPrompt(
        topic: TopicSuggestion,
        window: TimeWindow,
        profile: ProfileSnapshot,
        chapterNumber: Int,
        heading: String,
        previousHeadings: [String]
    ) -> String {
        let priorContext: String
        if previousHeadings.isEmpty {
            priorContext = firstChapterContext
        } else {
            let listed = previousHeadings
                .enumerated()
                .map { "Chapter \($0.offset + 1): \($0.element)" }
                .joined(separator: "\n")
            priorContext = "\(priorChaptersHeader)\n\(listed)"
        }

        var values = readerValues(profile)
        values["topic"] = topic.title
        values["chapterNumber"] = "\(chapterNumber)"
        values["chapterCount"] = "\(window.format.chapterCount)"
        values["chapterWordBudget"] = budgetPhrase(window.chapterWordBudget)
        values["heading"] = heading
        values["priorContext"] = priorContext
        return PromptTemplate.render(chapterTaskTemplate, values)
    }

    public static func suggestionTaskPrompt(
        window: TimeWindow,
        profile: ProfileSnapshot,
        history: [LessonDigest]
    ) -> String {
        let recent = history
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(SuggestionValidator.historyWindow)
            .map { "- \($0.title) [\($0.topicTag)]" }
            .joined(separator: "\n")

        var values = readerValues(profile)
        values["minutes"] = "\(window.minutes)"
        values["format"] = window.format.displayName
        values["history"] = recent.isEmpty ? noHistoryPlaceholder : recent
        return PromptTemplate.render(suggestionTaskTemplate, values)
    }

    public static func recallTaskPrompt(lesson: Lesson) -> String {
        PromptTemplate.render(recallTaskTemplate, [
            "title": lesson.title,
            "claim": lesson.surprisingClaim,
            "body": lesson.bodyMarkdown,
        ])
    }

    public static func postLessonTestTaskPrompt(lesson: Lesson) -> String {
        PromptTemplate.render(postLessonTestTaskTemplate, [
            "title": lesson.title,
            "claim": lesson.surprisingClaim,
            "body": lesson.bodyMarkdown,
        ])
    }

    public static func goDeeperTaskPrompt(
        window: TimeWindow,
        profile: ProfileSnapshot,
        parentTitle: String,
        angle: DeeperAngle
    ) -> String {
        var values = readerValues(profile)
        values["parentTitle"] = parentTitle
        values["angle"] = angle.text
        values["format"] = window.format.displayName
        values["minutes"] = "\(window.minutes)"
        values["wordBudget"] = budgetPhrase(window.wordBudget)
        values["structure"] = window.format.structureBrief
        return PromptTemplate.render(goDeeperTaskTemplate, values)
    }

    /// Every task template, for tests that assert placeholder hygiene.
    static let allTaskTemplates: [String: String] = [
        "lesson": lessonTaskTemplate,
        "revision": revisionTaskTemplate,
        "outline": outlineTaskTemplate,
        "chapter": chapterTaskTemplate,
        "suggestion": suggestionTaskTemplate,
        "recall": recallTaskTemplate,
        "postLessonTest": postLessonTestTaskTemplate,
        "goDeeper": goDeeperTaskTemplate,
    ]

    /// Every stable system prompt, for tests that assert they carry no
    /// per-call detail (which would silently break prompt caching).
    static let allSystemPrompts: [String: String] = [
        "editorial": editorialSystemPrompt,
        "revision": revisionSystemPrompt,
        "suggestion": suggestionSystemPrompt,
        "recall": recallSystemPrompt,
        "outline": outlineSystemPrompt,
        "postLessonTest": postLessonTestSystemPrompt,
    ]
}
