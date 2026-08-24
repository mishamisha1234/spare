import Foundation

/// Mechanical checks on generated prose. These catch the failure modes a
/// regex can see; the revision pass handles everything that needs judgement.
///
/// Two severities, and the difference is the whole design.
///
/// **Findings** are advisory. They are logged, they can trigger one retry, and
/// they never block a lesson from being read — a lesson with a banned phrase in
/// it is still a lesson.
///
/// **Failures** block. There is one, and it exists because the product's promise
/// is a length: a 15-minute lesson that runs 1,555 words against a 2,400-word
/// floor is about eight minutes of reading sold as fifteen. That is not a lesson
/// with a flaw in it, it is the wrong product, and no amount of it being
/// well-written makes the promise true. A failure is treated exactly as a
/// truncated stream is: not served, not cached, retried.
public enum LessonQualityCheck {

    // MARK: - Failures

    /// A reason a generated lesson may not be served at all.
    ///
    /// One case, deliberately. Everything else a regex can see is a finding —
    /// the bar for blocking is that the reader would be getting something other
    /// than what they chose, not that the writing could be better.
    public enum Failure: Equatable, Sendable, CustomStringConvertible {
        case underWordFloor(words: Int, floor: Int, hardFloor: Int)

        public var description: String {
            switch self {
            case .underWordFloor(let words, let floor, let hardFloor):
                return "\(words) words, under the hard floor of \(hardFloor)"
                    + " (90% of the \(floor)-word budget floor)"
            }
        }
    }

    /// How far under the budget floor a piece may land before it stops counting
    /// as the length it was sold as.
    ///
    /// 90% rather than 100% because the floor is a target and hitting it exactly
    /// every time is not a reasonable thing to ask of prose: a 2,400-floor lesson
    /// at 2,350 words is a rounding difference, and failing it would mean
    /// regenerating good lessons at Opus prices for thirty seconds of reading
    /// time. At 2,160 it is a different piece of writing.
    public static let hardFloorFraction = 0.9

    public static func hardFloor(for budget: ClosedRange<Int>) -> Int {
        Int((Double(budget.lowerBound) * hardFloorFraction).rounded())
    }

    /// The blocking check.
    ///
    /// Takes a budget rather than a `TimeWindow` for the same reason
    /// `Prompts.revisionTaskPrompt` does: a chapter of a course is measured
    /// against the chapter's budget, and a signature that accepts a window
    /// invites the caller to pass the course's by default. That mistake has
    /// already been made once in this pipeline and cost every 30-minute course.
    public static func failure(wordCount: Int, budget: ClosedRange<Int>) -> Failure? {
        let floor = hardFloor(for: budget)
        guard wordCount < floor else { return nil }
        return .underWordFloor(words: wordCount, floor: budget.lowerBound, hardFloor: floor)
    }

    public static func failure(for lesson: Lesson, window: TimeWindow) -> Failure? {
        failure(wordCount: lesson.wordCount, budget: window.wordBudget)
    }

    // MARK: - Findings

    public enum Finding: Equatable, Sendable, CustomStringConvertible {
        case bannedPhrase(String)
        case overBudget(words: Int, limit: Int)
        case wellUnderBudget(words: Int, floor: Int)
        case opensWithDefinition(String)
        case containsEmoji
        case closingRestatesOpening
        case wrongDeeperAngleCount(Int)
        case uniformSentenceLength(mean: Int)
        case bannedClosingConstruction(String)
        case displayedArithmetic(String)
        case tooManySections(count: Int, cap: Int, perChapter: Bool)
        case subtitleGivesAwayClaim

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
            case .bannedClosingConstruction(let opener):
                return "closing paragraph opens with \"\(opener)\""
            case .displayedArithmetic(let line):
                return "displayed arithmetic: \"\(line.prefix(60))\""
            case .tooManySections(let count, let cap, let perChapter):
                let unit = perChapter ? " in one chapter" : ""
                return "\(count) sections\(unit), ceiling is \(cap)"
            case .subtitleGivesAwayClaim:
                return "subtitle gives away the surprising claim"
            }
        }
    }

    public static func findings(for lesson: Lesson, window: TimeWindow) -> [Finding] {
        var findings: [Finding] = []
        let body = lesson.bodyMarkdown
        let lowered = body.lowercased()

        // Only the hard-banned list is checked mechanically.
        // `Prompts.advisoryBannedPhrases` (unlock, harness, leverage,
        // landscape, realm) are ordinary nouns and verbs a genuine topic can
        // need — flagging them here would reject correct writing. They're
        // left to the revision pass's judgment instead.
        for phrase in Prompts.hardBannedPhrases where lowered.contains(phrase) {
            findings.append(.bannedPhrase(phrase))
        }

        switch ReadingTime.budgetAssessment(wordCount: lesson.wordCount, window: window) {
        case .over(let by):
            findings.append(.overBudget(words: lesson.wordCount, limit: window.wordBudget.upperBound))
            _ = by
        case .under:
            // Every shortfall, not just a severe one.
            //
            // This used to start at a third under the floor. That threshold sits
            // far below the hard floor, so by the time it fired the lesson was
            // already being refused outright — the finding could only ever appear
            // on a lesson nobody would read. Reporting the whole band under the
            // floor is what makes the batch summary say "is this getting worse"
            // rather than "did it fall off a cliff".
            findings.append(
                .wellUnderBudget(words: lesson.wordCount, floor: window.wordBudget.lowerBound)
            )
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

        if let opener = bannedClosingOpener(in: body) {
            findings.append(.bannedClosingConstruction(opener))
        }

        if let line = displayedArithmetic(in: body) {
            findings.append(.displayedArithmetic(line))
        }

        let cap = window.format.maxSections
        let perChapter = window.format.isChaptered
        if let worst = sectionCounts(in: body, chaptered: perChapter).max(), worst > cap {
            findings.append(.tooManySections(count: worst, cap: cap, perChapter: perChapter))
        }

        if subtitleGivesAwayClaim(subtitle: lesson.subtitle, claim: lesson.surprisingClaim) {
            findings.append(.subtitleGivesAwayClaim)
        }

        return findings
    }

    // MARK: - Closing construction

    /// The one closing opener the whole batch reached for.
    ///
    /// Checked on the last prose paragraph only. `Prompts.bannedClosingOpeners`
    /// includes "look again at", which is a perfectly good mid-argument
    /// sentence — banning it everywhere would reject correct writing, which is
    /// the same line the advisory list is drawn on.
    static func bannedClosingOpener(in body: String) -> String? {
        guard let last = proseParagraphs(body).last else { return nil }
        let lowered = last.lowercased()
        // Longest first, so a match reports the phrase actually written rather
        // than a shorter one nested inside it.
        return Prompts.bannedClosingOpeners
            .sorted { $0.count > $1.count }
            .first { lowered.hasPrefix($0) }
    }

    // MARK: - Displayed arithmetic

    /// Deliberately excludes "*".
    ///
    /// It is the multiplication sign in code and the italic marker in markdown,
    /// and the editorial prompt tells the model to use italics — so every "*"
    /// this will ever see is emphasis. It cost a false positive on its first
    /// live run: a 200-word paragraph about Pacioli's *Summa* with two ordinary
    /// figures in it was reported as displayed arithmetic. Multiplication in
    /// prose is "\u{00D7}" anyway.
    static let arithmeticSymbols: Set<Character> = ["\u{00D7}", "\u{00F7}", "=", "^"]

    /// Longest a line can be and still be a *displayed* sum.
    ///
    /// The rule is "a line that is mostly an equation", and markdown puts a
    /// whole paragraph on one line — so without a length guard, "mostly" was
    /// measured across two hundred words of prose. A displayed calculation sits
    /// on a line of its own: the two the editorial report objected to were eight
    /// words and six.
    static let displayedArithmeticWordLimit = 25

    /// Deliberately excludes "/" and "-": dates, ranges, and hyphenated words
    /// would make them fire on ordinary prose.
    static let arithmeticConnectives = [
        " divided by ", " multiplied by ", " times ", " plus ", " minus ",
        " squared", " cubed", " square root ",
    ]

    static func displayedArithmetic(in body: String) -> String? {
        body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && isDisplayedArithmetic($0) }
    }

    /// "A line that is mostly an equation."
    ///
    /// Two digit runs are required before anything else is considered, and that
    /// requirement is what keeps the word forms honest: "three times a day,
    /// plus a fourth in winter" has two connectives and no digits, so it is
    /// prose. "41,250 square degrees, divided by twelve, times 0.7" has both.
    ///
    /// A multiplier suffix is not an equation — "2,400x brighter" carries one
    /// symbol and stays, which is why a single symbol is not enough on its own.
    static func isDisplayedArithmetic(_ line: String) -> Bool {
        guard numberRuns(in: line) >= 2 else { return false }

        // A chain of operators, or an equals sign, is a sum wherever it sits.
        // Neither survives in ordinary prose.
        if line.contains("=") { return true }
        if line.filter({ arithmeticSymbols.contains($0) }).count >= 2 { return true }

        // The written-out forms only count on a short line. In a long paragraph
        // "times" and "plus" are ordinary English and two of them are a
        // coincidence; on a line of its own, next to two figures, they are a
        // calculation the reader is being asked to follow.
        guard line.lessonWordCount <= displayedArithmeticWordLimit else { return false }
        let padded = " " + line.lowercased() + " "
        return arithmeticConnectives.filter { padded.contains($0) }.count >= 2
    }

    static func numberRuns(in text: String) -> Int {
        var runs = 0
        var inRun = false
        for character in text {
            if character.isNumber {
                if !inRun { runs += 1 }
                inRun = true
            } else if character != "," && character != "." {
                // A comma or a decimal point inside a figure keeps the run
                // going, so 41,250 counts once rather than twice.
                inRun = false
            }
        }
        return runs
    }

    // MARK: - Section count

    /// Sections per unit. One element for an unchaptered lesson; one per
    /// chapter, plus a leading element for anything before the first chapter
    /// heading, for a course.
    ///
    /// A course is counted per chapter because its chapter headings *are* its
    /// structure — counting them against the same ceiling as body sections
    /// would flag every course ever generated.
    static func sectionCounts(in body: String, chaptered: Bool) -> [Int] {
        var counts = [0]
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if chaptered, line.hasPrefix(LessonFormat.chapterHeadingPrefix) {
                counts.append(0)
            } else if line.hasPrefix("## ") {
                counts[counts.count - 1] += 1
            }
        }
        return counts
    }

    // MARK: - Subtitle

    /// True when the subtitle has already told the reader the reveal.
    ///
    /// Compared on four-character stems rather than whole words, because the
    /// giveaway is almost never a quotation: a claim about "the failure was
    /// geometric" gets a subtitle saying "they failed at geometry instead", and
    /// exact-word overlap sees nothing at all. Four is short enough to catch
    /// failed/failure and geometry/geometric, long enough that the 0.5 ratio
    /// still means something.
    static func subtitleGivesAwayClaim(subtitle: String, claim: String) -> Bool {
        let subtitleStems = stems(subtitle)
        let claimStems = stems(claim)
        guard subtitleStems.count >= 3, claimStems.count >= 3 else { return false }
        let overlap = subtitleStems.intersection(claimStems).count
        return Double(overlap) / Double(min(subtitleStems.count, claimStems.count)) > 0.5
    }

    static func stems(_ text: String) -> Set<String> {
        Set(contentWords(text).map { String($0.prefix(4)) })
    }

    // MARK: Helpers

    static func proseParagraphs(_ body: String) -> [String] {
        body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

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
        let paragraphs = proseParagraphs(body)
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
