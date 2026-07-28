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

    /// One chapter of a mini-course.
    public static let chapter: JSONValue = object(
        properties: [
            "heading": string("The chapter heading, without a number."),
            "bodyMarkdown": string("The chapter text in Markdown, ending with a single reflection prompt."),
        ],
        required: ["heading", "bodyMarkdown"]
    )

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

public struct ChapterResponse: Codable, Sendable, Equatable {
    public var heading: String
    public var bodyMarkdown: String

    public init(heading: String, bodyMarkdown: String) {
        self.heading = heading
        self.bodyMarkdown = bodyMarkdown
    }

    /// Markdown with the chapter number applied.
    public func markdown(chapterNumber: Int) -> String {
        "## Chapter \(chapterNumber): \(heading)\n\n\(bodyMarkdown)"
    }
}
