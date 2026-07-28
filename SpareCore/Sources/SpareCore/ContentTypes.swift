import Foundation

// MARK: - Reader context

/// How dense the reader wants their prose.
public enum Complexity: String, Codable, Sendable, CaseIterable {
    case plain
    case standard
    case dense

    public var promptDescription: String {
        switch self {
        case .plain: return "plain language, minimal jargon"
        case .standard: return "standard educated-reader register"
        case .dense: return "dense and technical; assume fast uptake"
        }
    }
}

/// Value copy of the user's profile. Providers never see persistence types.
public struct ProfileSnapshot: Sendable, Equatable, Codable {
    public var interests: [String]
    public var work: String
    /// "Things I nod along to but don't actually understand" — the
    /// highest-signal field for topic generation.
    public var curiosityGaps: [String]
    public var complexity: Complexity

    public init(
        interests: [String] = [],
        work: String = "",
        curiosityGaps: [String] = [],
        complexity: Complexity = .standard
    ) {
        self.interests = interests
        self.work = work
        self.curiosityGaps = curiosityGaps
        self.complexity = complexity
    }

    public static let empty = ProfileSnapshot()
}

/// Minimal record of a past lesson, used to exclude repeats from suggestions.
public struct LessonDigest: Sendable, Equatable, Codable {
    public var title: String
    public var topicTag: String
    public var completedAt: Date?

    public init(title: String, topicTag: String, completedAt: Date? = nil) {
        self.title = title
        self.topicTag = topicTag
        self.completedAt = completedAt
    }
}

// MARK: - Generated content

/// A topic the model proposes for the chosen window.
public struct TopicSuggestion: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// Max 7 words.
    public var title: String
    /// Max 14 words.
    public var hook: String
    public var domainTag: String
    /// The one deliberate pick from outside the user's stated interests.
    public var isWildcard: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        hook: String,
        domainTag: String,
        isWildcard: Bool = false
    ) {
        self.id = id
        self.title = title
        self.hook = hook
        self.domainTag = domainTag
        self.isWildcard = isWildcard
    }

    enum CodingKeys: String, CodingKey {
        case id, title, hook, domainTag, isWildcard
    }

    /// Model responses carry no `id`; one is minted on decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decode(String.self, forKey: .title)
        self.hook = try container.decode(String.self, forKey: .hook)
        self.domainTag = try container.decode(String.self, forKey: .domainTag)
        self.isWildcard = try container.decodeIfPresent(Bool.self, forKey: .isWildcard) ?? false
    }
}

/// Title, subtitle and tag, which arrive before the body during streaming.
public struct LessonMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var domainTag: String

    public init(title: String, subtitle: String, domainTag: String) {
        self.title = title
        self.subtitle = subtitle
        self.domainTag = domainTag
    }
}

/// A fully generated lesson.
public struct Lesson: Codable, Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var domainTag: String
    public var bodyMarkdown: String
    /// The load-bearing, checkable, counterintuitive claim.
    public var surprisingClaim: String
    /// Exactly 3 angles offered on the completion screen.
    public var deeperAngles: [String]

    public init(
        title: String,
        subtitle: String,
        domainTag: String,
        bodyMarkdown: String,
        surprisingClaim: String,
        deeperAngles: [String]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.domainTag = domainTag
        self.bodyMarkdown = bodyMarkdown
        self.surprisingClaim = surprisingClaim
        self.deeperAngles = deeperAngles
    }

    public var wordCount: Int { bodyMarkdown.lessonWordCount }

    public var metadata: LessonMetadata {
        LessonMetadata(title: title, subtitle: subtitle, domainTag: domainTag)
    }
}

/// One recall question, generated at completion and stored locally so
/// tomorrow's question is instant and works offline.
public struct RecallQuestion: Codable, Sendable, Equatable {
    public var question: String
    public var answer: String
    /// Exactly 3 plausible wrong options.
    public var distractors: [String]
    public var explanation: String

    public init(question: String, answer: String, distractors: [String], explanation: String) {
        self.question = question
        self.answer = answer
        self.distractors = distractors
        self.explanation = explanation
    }

    /// Answer plus distractors in a stable shuffled order derived from `seed`,
    /// so option order survives view reloads without being stored.
    public func options(seed: UInt64) -> [String] {
        var all = [answer] + distractors
        var state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        // Fisher-Yates with a small deterministic PRNG (xorshift64*).
        var index = all.count - 1
        while index > 0 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let random = state &* 0x2545F4914F6CDD1D
            let target = Int(random % UInt64(index + 1))
            all.swapAt(index, target)
            index -= 1
        }
        return all
    }
}

/// A "go deeper" direction, taken from `Lesson.deeperAngles`.
public struct DeeperAngle: Codable, Sendable, Hashable, Identifiable {
    public var text: String
    public var id: String { text }

    public init(text: String) {
        self.text = text
    }
}

// MARK: - Entitlement

public enum Tier: String, Codable, Sendable, CaseIterable {
    case free
    case monthly
    case yearly
    case lifetime

    public var isPremium: Bool { self != .free }
}
