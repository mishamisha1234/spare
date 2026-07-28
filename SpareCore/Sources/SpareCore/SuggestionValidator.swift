import Foundation

/// Enforces the suggestion rules on whatever the model returns, before the user
/// sees it. Prompting asks for these; validation is what guarantees them.
public enum SuggestionValidator {

    public static let requiredCount = 5
    public static let minimumDomains = 3
    public static let maxTitleWords = 7
    public static let maxHookWords = 14
    /// Suggestions are checked against the most recent N completed lessons.
    public static let historyWindow = 30

    public enum Issue: Equatable, Sendable, CustomStringConvertible {
        case wrongCount(Int)
        case tooFewDomains(Int)
        case wildcardCount(Int)
        case titleTooLong(title: String, words: Int)
        case hookTooLong(title: String, words: Int)
        case clickbait(title: String, phrase: String)
        case duplicateOfHistory(title: String)
        case duplicateWithinSet(title: String)
        case emptyField(title: String, field: String)
        case noCuriosityGapConnection

        public var description: String {
            switch self {
            case .wrongCount(let count):
                return "expected \(requiredCount) suggestions, got \(count)"
            case .tooFewDomains(let count):
                return "suggestions span \(count) domains, need at least \(minimumDomains)"
            case .wildcardCount(let count):
                return "expected exactly 1 wildcard, got \(count)"
            case .titleTooLong(let title, let words):
                return "title \"\(title)\" is \(words) words (max \(maxTitleWords))"
            case .hookTooLong(let title, let words):
                return "hook for \"\(title)\" is \(words) words (max \(maxHookWords))"
            case .clickbait(let title, let phrase):
                return "title \"\(title)\" contains clickbait phrase \"\(phrase)\""
            case .duplicateOfHistory(let title):
                return "\"\(title)\" repeats a recently completed lesson"
            case .duplicateWithinSet(let title):
                return "\"\(title)\" appears twice in the same set"
            case .emptyField(let title, let field):
                return "\"\(title)\" has an empty \(field)"
            case .noCuriosityGapConnection:
                return "no suggestion connects to a stated curiosity gap"
            }
        }

        /// Whether the issue should force a regeneration rather than be logged.
        public var isBlocking: Bool {
            switch self {
            case .wrongCount, .tooFewDomains, .wildcardCount,
                 .duplicateOfHistory, .duplicateWithinSet, .emptyField:
                return true
            // Length and tone slips are trimmed/tolerated rather than blocking.
            case .titleTooLong, .hookTooLong, .clickbait, .noCuriosityGapConnection:
                return false
            }
        }
    }

    static let clickbaitPhrases = [
        "you won't believe",
        "you wont believe",
        "this one trick",
        "will blow your mind",
        "mind-blowing",
        "shocking truth",
        "what happened next",
        "doctors hate",
        "here's why you",
        "nobody talks about",
    ]

    public static func validate(
        _ suggestions: [TopicSuggestion],
        history: [LessonDigest] = [],
        profile: ProfileSnapshot = .empty
    ) -> [Issue] {
        var issues: [Issue] = []

        if suggestions.count != requiredCount {
            issues.append(.wrongCount(suggestions.count))
        }

        let domains = Set(suggestions.map { normalize($0.domainTag) }).filter { !$0.isEmpty }
        if domains.count < minimumDomains {
            issues.append(.tooFewDomains(domains.count))
        }

        let wildcards = suggestions.filter(\.isWildcard).count
        if wildcards != 1 {
            issues.append(.wildcardCount(wildcards))
        }

        var seenTitles = Set<String>()
        let recentTitles = Set(
            history
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .prefix(historyWindow)
                .map { normalize($0.title) }
        )

        for suggestion in suggestions {
            let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                issues.append(.emptyField(title: suggestion.title, field: "title"))
            }
            if suggestion.hook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyField(title: suggestion.title, field: "hook"))
            }
            if suggestion.domainTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyField(title: suggestion.title, field: "domainTag"))
            }

            let titleWords = title.lessonWordCount
            if titleWords > maxTitleWords {
                issues.append(.titleTooLong(title: title, words: titleWords))
            }
            let hookWords = suggestion.hook.lessonWordCount
            if hookWords > maxHookWords {
                issues.append(.hookTooLong(title: title, words: hookWords))
            }

            let lowered = title.lowercased()
            for phrase in clickbaitPhrases where lowered.contains(phrase) {
                issues.append(.clickbait(title: title, phrase: phrase))
            }

            let key = normalize(title)
            if !key.isEmpty {
                if seenTitles.contains(key) {
                    issues.append(.duplicateWithinSet(title: title))
                }
                seenTitles.insert(key)
                if recentTitles.contains(key) {
                    issues.append(.duplicateOfHistory(title: title))
                }
            }
        }

        if !profile.curiosityGaps.isEmpty, !connectsToCuriosityGap(suggestions, profile: profile) {
            issues.append(.noCuriosityGapConnection)
        }

        return issues
    }

    /// True when the set is fit to show without regenerating.
    public static func isAcceptable(
        _ suggestions: [TopicSuggestion],
        history: [LessonDigest] = [],
        profile: ProfileSnapshot = .empty
    ) -> Bool {
        !validate(suggestions, history: history, profile: profile).contains(where: \.isBlocking)
    }

    /// Best-effort repair for non-blocking slips: trims over-long titles and
    /// hooks at a word boundary so a nearly-good set is still usable.
    public static func repairing(_ suggestions: [TopicSuggestion]) -> [TopicSuggestion] {
        suggestions.map { suggestion in
            var repaired = suggestion
            repaired.title = truncate(suggestion.title, toWords: maxTitleWords)
            repaired.hook = truncate(suggestion.hook, toWords: maxHookWords)
            return repaired
        }
    }

    static func truncate(_ text: String, toWords limit: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count > limit else { return text }
        return words.prefix(limit).joined(separator: " ")
    }

    /// Loose lexical overlap check — deliberately not semantic. The prompt does
    /// the semantic work; this catches only obvious echoes of a stated gap.
    static func connectsToCuriosityGap(
        _ suggestions: [TopicSuggestion],
        profile: ProfileSnapshot
    ) -> Bool {
        let gapWords = Set(
            profile.curiosityGaps
                .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }) }
                .map(String.init)
                .filter { $0.count > 3 }
        )
        guard !gapWords.isEmpty else { return true }
        for suggestion in suggestions {
            let text = (suggestion.title + " " + suggestion.hook + " " + suggestion.domainTag).lowercased()
            let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
            if !words.intersection(gapWords).isEmpty { return true }
        }
        return false
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
