import Foundation

/// Mechanical checks on generated prose. These catch the failure modes a
/// regex can see; the revision pass handles everything that needs judgement.
///
/// Findings are advisory: they are logged and can trigger one retry, but they
/// never block a lesson from being read.
public enum LessonQualityCheck {

    public enum Finding: Equatable, Sendable, CustomStringConvertible {
        case bannedPhrase(String)
        case overBudget(words: Int, limit: Int)
        case wellUnderBudget(words: Int, floor: Int)
        case opensWithDefinition(String)
        case containsEmoji
        case closingRestatesOpening
        case wrongDeeperAngleCount(Int)
        case uniformSentenceLength(mean: Int)

        public var description: String {
            switch self {
            case .bannedPhrase(let phrase): return "banned phrase: \"\(phrase)\""
            case .overBudget(let words, let limit): return "\(words) words, over the \(limit) ceiling"
            case .wellUnderBudget(let words, let floor): return "\(words) words, well under the \(floor) floor"
            case .opensWithDefinition(let opener): return "opens with a definition: \"\(opener)\""
            case .containsEmoji: return "contains emoji"
            case .closingRestatesOpening: return "closing paragraph echoes the opening"
            case .wrongDeeperAngleCount(let count): return "\(count) deeper angles, expected 3"
            case .uniformSentenceLength(let mean): return "sentence lengths uniform around \(mean) words"
            }
        }
    }

    public static func findings(for lesson: Lesson, window: TimeWindow) -> [Finding] {
        var findings: [Finding] = []
        let body = lesson.bodyMarkdown
        let lowered = body.lowercased()

        for phrase in Prompts.bannedPhrases where lowered.contains(phrase) {
            // "leverage" is banned as a verb only; allow the noun in finance
            // contexts rather than flagging every legitimate use.
            if phrase == "leverage", !lowered.contains("leveraging"), !lowered.contains("to leverage") {
                continue
            }
            findings.append(.bannedPhrase(phrase))
        }

        switch ReadingTime.budgetAssessment(wordCount: lesson.wordCount, window: window) {
        case .over(let by):
            findings.append(.overBudget(words: lesson.wordCount, limit: window.wordBudget.upperBound))
            _ = by
        case .under(let by):
            // Tight is fine; a third under budget is thin.
            if by > window.wordBudget.lowerBound / 3 {
                findings.append(.wellUnderBudget(words: lesson.wordCount, floor: window.wordBudget.lowerBound))
            }
        case .onTarget:
            break
        }

        if let opener = firstSentence(of: body), opensWithDefinition(opener) {
            findings.append(.opensWithDefinition(opener))
        }

        if body.unicodeScalars.contains(where: isEmojiScalar) {
            findings.append(.containsEmoji)
        }

        if lesson.deeperAngles.count != 3 {
            findings.append(.wrongDeeperAngleCount(lesson.deeperAngles.count))
        }

        if closingRestatesOpening(body) {
            findings.append(.closingRestatesOpening)
        }

        let lengths = sentenceWordLengths(of: body)
        if lengths.count >= 6, let mean = uniformMean(lengths) {
            findings.append(.uniformSentenceLength(mean: mean))
        }

        return findings
    }

    // MARK: Helpers

    static func firstSentence(of text: String) -> String? {
        let prose = text
            .split(separator: "\n")
            .first { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
        guard let prose else { return nil }
        let sentence = prose.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }).first
        return sentence.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static let definitionOpeners = [
        " is a ", " is an ", " is the ", " refers to ", " can be defined as ",
        " are a ", " are the ", " means ",
    ]

    static func opensWithDefinition(_ sentence: String) -> Bool {
        let lowered = " " + sentence.lowercased() + " "
        // A definition opener has no concrete anchor: no digit, no capitalized
        // proper noun after the first word.
        let hasNumber = sentence.contains(where: \.isNumber)
        if hasNumber { return false }
        return definitionOpeners.contains { lowered.contains($0) }
    }

    static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        // Emoji presentation, pictographs, and the variation selector used to
        // force emoji rendering. Deliberately narrow to avoid flagging dashes,
        // quotes, or accented Latin text.
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1F300...0x1FAFF, 0x2600...0x27BF, 0xFE0F:
            return true
        default:
            return false
        }
    }

    static func closingRestatesOpening(_ body: String) -> Bool {
        let paragraphs = body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard paragraphs.count >= 3,
              let first = paragraphs.first,
              let last = paragraphs.last else { return false }

        let firstWords = contentWords(first)
        let lastWords = contentWords(last)
        guard firstWords.count >= 8, lastWords.count >= 8 else { return false }
        let overlap = firstWords.intersection(lastWords).count
        let ratio = Double(overlap) / Double(min(firstWords.count, lastWords.count))
        return ratio > 0.55
    }

    static let stopWords: Set<String> = [
        "the", "and", "that", "this", "with", "from", "for", "was", "were", "are",
        "but", "not", "you", "your", "its", "it's", "they", "them", "their", "then",
        "than", "have", "has", "had", "what", "when", "where", "which", "who", "how",
        "all", "any", "one", "two", "out", "into", "over", "under", "just", "more",
        "most", "some", "such", "only", "own", "same", "very", "can", "will", "would",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && $0 != "'" })
                .map(String.init)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    static func sentenceWordLengths(of text: String) -> [Int] {
        text
            .split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" })
            .map { $0.lessonWordCount }
            .filter { $0 > 0 }
    }

    /// Returns the mean when sentence lengths are suspiciously uniform: mean in
    /// the 15–25 band and standard deviation under 5 words.
    static func uniformMean(_ lengths: [Int]) -> Int? {
        guard !lengths.isEmpty else { return nil }
        let mean = Double(lengths.reduce(0, +)) / Double(lengths.count)
        guard (15.0...25.0).contains(mean) else { return nil }
        let variance = lengths.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(lengths.count)
        guard variance.squareRoot() < 5 else { return nil }
        return Int(mean.rounded())
    }
}
