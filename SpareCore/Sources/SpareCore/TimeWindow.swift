import Foundation

/// The shape a lesson takes at a given length.
public enum LessonFormat: String, Codable, Sendable, CaseIterable {
    case oneThing
    case explainer
    case lesson
    case miniCourse

    public var displayName: String {
        switch self {
        case .oneThing: return "One Thing"
        case .explainer: return "Explainer"
        case .lesson: return "Lesson"
        case .miniCourse: return "Mini-course"
        }
    }

    /// The most "## " sections one unit of this format may carry.
    ///
    /// A ceiling, not a target: the first batch showed the failure this exists
    /// to catch, which is a lesson quietly becoming two. A second good argument
    /// arrives, gets its own heading, and the reader finishes tired instead of
    /// wanting another one. Both the prompt and `LessonQualityCheck` read this
    /// number, so they cannot disagree about what the limit is.
    ///
    /// For a mini-course the cap is *per chapter*. The chapter headings
    /// themselves are the course's structure and are counted separately.
    public var maxSections: Int {
        switch self {
        case .oneThing: return 0
        case .explainer: return 3
        case .lesson: return 5
        case .miniCourse: return 3
        }
    }

    /// Structural instruction handed to the model.
    ///
    /// Interpolates `maxSections` rather than restating it, so the number the
    /// model is told and the number the quality check enforces are the same
    /// number.
    public var structureBrief: String {
        switch self {
        case .oneThing:
            return "A single idea, explained properly. No sections and no headings at all. One concrete hook, one mechanism, one reason it matters."
        case .explainer:
            return "At most \(maxSections) sections — a ceiling, not a target. One analogy that actually maps, one paragraph long. One genuinely surprising detail."
        case .lesson:
            return "At most \(maxSections) sections — a ceiling, not a target — including one worked example or case walked through in detail."
        case .miniCourse:
            return "\(chapterCount) chapters, each building on the last, at most \(maxSections) sections inside any one chapter, each ending with a single reflection prompt."
        }
    }

    /// Number of chapters generated lazily, one at a time. Only the
    /// mini-course is chaptered; everything else is a single unit.
    public var chapterCount: Int {
        switch self {
        case .oneThing, .explainer, .lesson: return 1
        case .miniCourse: return 4
        }
    }

    public var isChaptered: Bool { chapterCount > 1 }

    /// The literal prefix every chapter heading carries in an assembled course
    /// body.
    ///
    /// Shared rather than written out at each site: `GenerationPipeline` emits
    /// it, `MockProvider` mimics it, and `LessonQualityCheck` splits a course on
    /// it to count sections per chapter. Three copies of the same string is
    /// three chances for the section cap to start counting chapter headings as
    /// sections.
    public static let chapterHeadingPrefix = "## Chapter "

    public static func chapterHeading(number: Int, text: String) -> String {
        "\(chapterHeadingPrefix)\(number): \(text)"
    }
}

/// Time is the input. Everything else in the app hangs off this choice.
public enum TimeWindow: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    // Declaration order is ascending, and it is load-bearing: `allCases` is
    // what Home lays out and what the batch tool iterates.
    case one
    case three
    case seven
    case fifteen
    case thirty

    public var id: String { rawValue }

    public var minutes: Int {
        switch self {
        case .one: return 1
        case .three: return 3
        case .seven: return 7
        case .fifteen: return 15
        case .thirty: return 30
        }
    }

    /// The window whose length is nearest a given reading time.
    ///
    /// For recovering the window of an already-written lesson: a `Lesson`
    /// records its text, not the choice that produced it.
    public static func closest(toMinutes minutes: Int) -> TimeWindow {
        allCases.min(by: { abs($0.minutes - minutes) < abs($1.minutes - minutes) }) ?? .three
    }

    /// Word budgets calibrated to ~200 wpm minus absorption overhead.
    public var wordBudget: ClosedRange<Int> {
        switch self {
        // A minute is a target, not a fixed length. 200 words is the middle of
        // this; the band is wide because at one minute the difference between
        // 180 and 240 words is a sentence either way, and a hard number would
        // fail lessons over punctuation.
        case .one: return 180...240
        case .three: return 500...650
        case .seven: return 1100...1400
        case .fifteen: return 2400...3000
        // 6,000-6,400 divides cleanly by 4 chapters into 1,500-1,600 words
        // each. Four rather than three deliberately: three chapters collapse
        // into intro/middle/conclusion, and the chapter break is what makes a
        // course resumable on a phone.
        case .thirty: return 6000...6400
        }
    }

    public var format: LessonFormat {
        switch self {
        // A minute and three minutes are the same shape at different depths:
        // one idea, no headings. What changes is how far it is taken.
        case .one, .three: return .oneThing
        case .seven: return .explainer
        case .fifteen: return .lesson
        case .thirty: return .miniCourse
        }
    }

    /// The duration, for navigation titles, paywall copy, and anywhere a
    /// window needs naming in prose. Home's fourth circle does *not* use
    /// this — see `circleTitle`.
    public var label: String { "\(minutes) min" }

    /// Home's primary circle label. A course is named for what it is rather
    /// than how long it takes, because it isn't one sitting: the duration
    /// moves to `circleSubtitle` underneath.
    public var circleTitle: String {
        format.isChaptered ? "Course" : label
    }

    /// The second line under a course circle. `nil` for the single-sitting
    /// windows, whose duration is already the title.
    public var circleSubtitle: String? {
        guard format.isChaptered else { return nil }
        return "\(label) · \(format.chapterCount) chapters"
    }

    /// Decodes a persisted raw value, tolerating ones this app no longer
    /// writes.
    ///
    /// `"fortyFive"` predates courses moving from 45 minutes to 30, and
    /// `"ten"` predates the 10-minute explainer becoming a 7-minute one. A
    /// plain `init(rawValue:)` returns nil for both, and the call site's
    /// `?? .three` would silently turn somebody's course — or their explainer —
    /// into a 3-minute One Thing. Each maps to the window that replaced it.
    ///
    /// This is the whole reason the function exists rather than the call sites
    /// using `init(rawValue:)`: a renamed case that decodes to a wrong default
    /// is invisible. Nothing crashes, nothing logs, the reader just finds a
    /// different lesson than the one they saved.
    public static func stored(rawValue: String) -> TimeWindow? {
        if let window = TimeWindow(rawValue: rawValue) { return window }
        return legacyRawValues[rawValue]
    }

    /// Raw values this app no longer writes, and the window each becomes.
    ///
    /// A table rather than a chain of `if`s because two separate things read
    /// it: `stored(rawValue:)`, which decodes an old row on the way in, and the
    /// migration that rewrites those rows so they stop being old. Those two
    /// disagreeing would be worse than having no migration at all — the
    /// library would show one thing and the stored data would say another,
    /// and only one of them would survive the next write.
    public static let legacyRawValues: [String: TimeWindow] = [
        // Courses were 45 minutes before they were 30.
        "fortyFive": .thirty,
        // The explainer was 10 minutes before it was 7.
        "ten": .seven,
    ]

    /// Free tier covers the two middle windows.
    ///
    /// Not the two shortest, which it used to be and which reads as the
    /// obvious shape. The 1-minute length is premium on purpose: it is the
    /// counterintuitive one, and "the shortest is the paid one" is what makes
    /// a free reader stop and look at it.
    public var isFreeTierEligible: Bool {
        switch self {
        case .three, .seven: return true
        case .one, .fifteen, .thirty: return false
        }
    }

    /// Questions in the post-lesson test for this length.
    ///
    /// Fixed per duration rather than proportional to word count: the test is
    /// a check on what stuck, and ten questions on a 3-minute One Thing would
    /// be interrogating a single idea from ten angles. The course gets ten
    /// because it has four chapters to cover and a reader who finished one has
    /// spent half an hour earning the right to be asked properly.
    ///
    /// The server validates an uploaded test against this exact number, so it
    /// is a contract and not a suggestion.
    public var testQuestionCount: Int {
        switch self {
        case .one: return 2
        case .three: return 3
        case .seven: return 4
        case .fifteen: return 5
        case .thirty: return 10
        }
    }

    /// Per-chapter word budget for chaptered formats; the whole budget otherwise.
    public var chapterWordBudget: ClosedRange<Int> {
        let chapters = format.chapterCount
        guard chapters > 1 else { return wordBudget }
        return (wordBudget.lowerBound / chapters)...(wordBudget.upperBound / chapters)
    }
}
