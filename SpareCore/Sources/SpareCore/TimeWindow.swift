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
    case three
    case ten
    case fifteen
    case thirty

    public var id: String { rawValue }

    public var minutes: Int {
        switch self {
        case .three: return 3
        case .ten: return 10
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
        case .three: return 500...650
        case .ten: return 1600...2000
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
        case .three: return .oneThing
        case .ten: return .explainer
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
    /// `"fortyFive"` predates courses moving from 45 minutes to 30. A plain
    /// `init(rawValue:)` returns nil for it, and the call site's `?? .three`
    /// would silently turn somebody's course into a 3-minute One Thing —
    /// so it maps to the window that actually replaced it instead.
    public static func stored(rawValue: String) -> TimeWindow? {
        if let window = TimeWindow(rawValue: rawValue) { return window }
        if rawValue == "fortyFive" { return .thirty }
        return nil
    }

    /// Free tier covers only the two shortest windows.
    public var isFreeTierEligible: Bool {
        switch self {
        case .three, .ten: return true
        case .fifteen, .thirty: return false
        }
    }

    /// Per-chapter word budget for chaptered formats; the whole budget otherwise.
    public var chapterWordBudget: ClosedRange<Int> {
        let chapters = format.chapterCount
        guard chapters > 1 else { return wordBudget }
        return (wordBudget.lowerBound / chapters)...(wordBudget.upperBound / chapters)
    }
}
