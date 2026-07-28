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

    /// Structural instruction handed to the model.
    public var structureBrief: String {
        switch self {
        case .oneThing:
            return "A single idea, explained properly. No sections. One concrete hook, one mechanism, one reason it matters."
        case .explainer:
            return "Three sections. One analogy that actually maps. One genuinely surprising detail."
        case .lesson:
            return "Four to five sections, including one worked example or case walked through in detail."
        case .miniCourse:
            return "Five to six chapters, each building on the last, each ending with a single reflection prompt."
        }
    }

    /// Number of chapters generated lazily, one at a time. Only the
    /// mini-course is chaptered; everything else is a single unit.
    public var chapterCount: Int {
        switch self {
        case .oneThing, .explainer, .lesson: return 1
        case .miniCourse: return 6
        }
    }

    public var isChaptered: Bool { chapterCount > 1 }
}

/// Time is the input. Everything else in the app hangs off this choice.
public enum TimeWindow: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case three
    case ten
    case fifteen
    case fortyFive

    public var id: String { rawValue }

    public var minutes: Int {
        switch self {
        case .three: return 3
        case .ten: return 10
        case .fifteen: return 15
        case .fortyFive: return 45
        }
    }

    /// Word budgets calibrated to ~200 wpm minus absorption overhead.
    public var wordBudget: ClosedRange<Int> {
        switch self {
        case .three: return 500...650
        case .ten: return 1600...2000
        case .fifteen: return 2400...3000
        case .fortyFive: return 7000...9000
        }
    }

    public var format: LessonFormat {
        switch self {
        case .three: return .oneThing
        case .ten: return .explainer
        case .fifteen: return .lesson
        case .fortyFive: return .miniCourse
        }
    }

    public var label: String { "\(minutes) min" }

    /// Free tier covers only the two shortest windows.
    public var isFreeTierEligible: Bool {
        switch self {
        case .three, .ten: return true
        case .fifteen, .fortyFive: return false
        }
    }

    /// Per-chapter word budget for chaptered formats; the whole budget otherwise.
    public var chapterWordBudget: ClosedRange<Int> {
        let chapters = format.chapterCount
        guard chapters > 1 else { return wordBudget }
        return (wordBudget.lowerBound / chapters)...(wordBudget.upperBound / chapters)
    }
}
