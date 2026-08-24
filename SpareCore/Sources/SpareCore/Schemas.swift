import Foundation

/// JSON schemas for structured outputs (`output_config.format`). Using the
/// API's schema enforcement rather than asking the prompt for "JSON only"
/// means malformed responses stop being a failure mode.
///
/// Constraints observed: every object sets `additionalProperties: false` and
/// lists all keys in `required`; no numeric/length constraints (unsupported),
/// so counts are enforced by `SuggestionValidator` after decoding.
public enum Schemas {

    private static func object(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func string(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    /// Five topic suggestions.
    public static let topicSuggestions: JSONValue = object(
        properties: [
            "suggestions": .object([
                "type": .string("array"),
                "description": .string("Exactly 5 suggestions."),
                "items": object(
                    properties: [
                        "title": string("Maximum 7 words."),
                        "hook": string("One line, maximum 14 words."),
                        "domainTag": string("Single-word or two-word domain, e.g. Physics, Economic history."),
                        "isWildcard": .object([
                            "type": .string("boolean"),
                            "description": .string("True for exactly one suggestion: the deliberate pick from outside the reader's stated interests."),
                        ]),
                    ],
                    required: ["title", "hook", "domainTag", "isWildcard"]
                ),
            ]),
        ],
        required: ["suggestions"]
    )

    /// A complete lesson (draft or revised).
    public static let lesson: JSONValue = object(
        properties: [
            "title": string("The lesson title."),
            "subtitle": string("One line beneath the title."),
            "domainTag": string("Single-word or two-word domain."),
            "bodyMarkdown": string("The lesson itself, in Markdown."),
            "surprisingClaim": string("The one load-bearing, checkable, counterintuitive claim in the piece."),
            "deeperAngles": .object([
                "type": .string("array"),
                "description": .string("Exactly 3 angles: broader context, a specific mechanism, a counterargument."),
                "items": .object(["type": .string("string")]),
            ]),
        ],
        required: ["title", "subtitle", "domainTag", "bodyMarkdown", "surprisingClaim", "deeperAngles"]
    )

    /// The plan for a mini-course, produced before any chapter is written.
    ///
    /// Exists because chaptered lessons still need lesson-level metadata —
    /// title, the load-bearing claim, and the three "go deeper" angles the
    /// Completion screen offers. Generating it first (rather than after the
    /// last chapter) means a reader who stops at chapter 2 still has a
    /// properly titled entry in their library.
    public static let courseOutline: JSONValue = object(
        properties: [
            "title": string("The course title."),
            "subtitle": string("One line beneath the title."),
            "domainTag": string("Single-word or two-word domain."),
            "surprisingClaim": string("The one load-bearing, checkable, counterintuitive claim the course is built around."),
            "deeperAngles": .object([
                "type": .string("array"),
                "description": .string("Exactly 3 angles: broader context, a specific mechanism, a counterargument."),
                "items": .object(["type": .string("string")]),
            ]),
            "chapterHeadings": .object([
                "type": .string("array"),
                "description": .string("One heading per chapter, in order, plain text with no numbering."),
                "items": .object(["type": .string("string")]),
            ]),
        ],
        required: ["title", "subtitle", "domainTag", "surprisingClaim", "deeperAngles", "chapterHeadings"]
    )

    /// One chapter of a mini-course.
    public static let chapter: JSONValue = object(
        properties: [
            "heading": string("The chapter heading, without a number."),
            "bodyMarkdown": string("The chapter text in Markdown, ending with a single reflection prompt."),
        ],
        required: ["heading", "bodyMarkdown"]
    )

    /// The immediate, optional post-lesson test (premium). Wrapped in an object
    /// like `topicSuggestions`, since a top-level array is not a valid
    /// structured-output root.
    ///
    /// A function of the count rather than a constant, because the count is a
    /// function of the duration: two questions on a 1-minute One Thing, ten on
    /// a 30-minute course. The number lives in `TimeWindow.testQuestionCount`
    /// and reaches both the schema and the task prompt from there, so the shape
    /// the model is asked for and the shape the server will accept cannot
    /// drift apart.
    public static func postLessonTest(questionCount: Int) -> JSONValue {
        object(
            properties: [
                "questions": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Exactly \(questionCount) questions, each testing a different part of the lesson."
                    ),
                    "items": object(
                        properties: [
                            "question": string("One question testing part of the lesson, not a trivia detail."),
                            "answer": string("The correct option."),
                            "distractors": .object([
                                "type": .string("array"),
                                "description": .string("Exactly 3 plausible wrong options a careless reader would fall for."),
                                "items": .object(["type": .string("string")]),
                            ]),
                            "explanation": string("One sentence on why the answer is right."),
                        ],
                        required: ["question", "answer", "distractors", "explanation"]
                    ),
                ]),
            ],
            required: ["questions"]
        )
    }

    /// A recall question.
    public static let recallQuestion: JSONValue = object(
        properties: [
            "question": string("One question testing the central idea, not a trivia detail."),
            "answer": string("The correct option."),
            "distractors": .object([
                "type": .string("array"),
                "description": .string("Exactly 3 plausible wrong options a person who half-read the lesson would fall for."),
                "items": .object(["type": .string("string")]),
            ]),
            "explanation": string("One sentence on why the answer is right."),
        ],
        required: ["question", "answer", "distractors", "explanation"]
    )
}

// MARK: - Response envelopes

/// The suggestions schema wraps the array in an object, because a top-level
/// array is not a valid structured-output root.
public struct TopicSuggestionsResponse: Codable, Sendable {
    public var suggestions: [TopicSuggestion]

    public init(suggestions: [TopicSuggestion]) {
        self.suggestions = suggestions
    }
}

public struct CourseOutlineResponse: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var domainTag: String
    public var surprisingClaim: String
    public var deeperAngles: [String]
    public var chapterHeadings: [String]

    public init(
        title: String,
        subtitle: String,
        domainTag: String,
        surprisingClaim: String,
        deeperAngles: [String],
        chapterHeadings: [String]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.domainTag = domainTag
        self.surprisingClaim = surprisingClaim
        self.deeperAngles = deeperAngles
        self.chapterHeadings = chapterHeadings
    }

    /// JSON Schema can't constrain array length, so the count is enforced
    /// here: pad with a neutral heading or truncate to the chapter count.
    public func headings(paddedTo count: Int) -> [String] {
        guard chapterHeadings.count != count else { return chapterHeadings }
        if chapterHeadings.count > count {
            return Array(chapterHeadings.prefix(count))
        }
        return chapterHeadings + (chapterHeadings.count..<count).map { "Part \($0 + 1)" }
    }

    public var metadata: LessonMetadata {
        LessonMetadata(title: title, subtitle: subtitle, domainTag: domainTag)
    }
}

public struct PostLessonTestResponse: Codable, Sendable, Equatable {
    public var questions: [RecallQuestion]

    public init(questions: [RecallQuestion]) {
        self.questions = questions
    }

    /// JSON Schema can't constrain array length. Truncating an over-long
    /// response is safe; padding a short one is not — a fabricated recall
    /// question would be worse content than simply showing fewer.
    ///
    /// Takes the count rather than assuming three, now that it varies by
    /// length. A short response still comes back short: the server rejects an
    /// uploaded test whose count is wrong, so a lesson generated with a
    /// too-short test carries no test rather than a padded one. That is the
    /// right way round — the test is the thing premium pays for, and a
    /// fabricated question is worse than a missing one.
    public func normalizedQuestions(count: Int) -> [RecallQuestion] {
        Array(questions.prefix(max(0, count)))
    }
}

public struct ChapterResponse: Codable, Sendable, Equatable {
    public var heading: String
    public var bodyMarkdown: String

    public init(heading: String, bodyMarkdown: String) {
        self.heading = heading
        self.bodyMarkdown = bodyMarkdown
    }

    /// Markdown with the chapter number applied.
    public func markdown(chapterNumber: Int) -> String {
        LessonFormat.chapterHeading(number: chapterNumber, text: heading)
            + "\n\n\(bodyMarkdown)"
    }
}
