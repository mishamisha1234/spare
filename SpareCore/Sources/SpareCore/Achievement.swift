import Foundation

/// A single unlocked achievement. No progress bar, no tiers shown to the
/// user beyond the title — the aesthetic rule for this feature is a quiet
/// line of text, not a badge.
public struct Achievement: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// What achievement evaluation needs from the library, as a value snapshot
/// rather than SwiftData — so it is testable without a model container, and
/// so `Achievements` never has to know a `@Model` type exists.
public struct LibrarySnapshot: Sendable, Equatable {
    public var completedLessonCount: Int
    public var completedMiniCourseCount: Int
    /// One entry per completed lesson's domain tag; duplicates included. The
    /// breadth achievement only cares about the distinct set, but callers
    /// building this from a lesson list don't have to deduplicate first.
    public var completedDomains: [String]

    public init(
        completedLessonCount: Int,
        completedMiniCourseCount: Int,
        completedDomains: [String]
    ) {
        self.completedLessonCount = completedLessonCount
        self.completedMiniCourseCount = completedMiniCourseCount
        self.completedDomains = completedDomains
    }

    public static let empty = LibrarySnapshot(
        completedLessonCount: 0, completedMiniCourseCount: 0, completedDomains: []
    )
}

/// Every achievement is a pure function of the points ledger and a library
/// snapshot. None is ever "awarded" and stored — an achievement is always
/// recomputed from the same source history the points ledger already keeps,
/// the same event-sourced principle applied one level up.
public enum Achievements {

    static let countThresholds = [10, 50, 100, 500]
    static let consistencyThresholds = [30, 100, 365]
    static let depthThreshold = 10
    static let retentionMinimumAttempts = 50
    static let retentionMinimumRate = 0.9

    public static func unlocked(
        events: [PointEvent],
        library: LibrarySnapshot,
        calendar: Calendar = .current
    ) -> [Achievement] {
        var result: [Achievement] = []

        for threshold in countThresholds where library.completedLessonCount >= threshold {
            result.append(Achievement(id: "count-\(threshold)", title: "\(threshold) things known"))
        }

        if !Domains.all.isEmpty,
           Domains.all.allSatisfy({ canonical in
               library.completedDomains.contains { Domains.matches($0, canonical) }
           }) {
            result.append(Achievement(id: "breadth-all", title: "Every domain"))
        }

        if library.completedMiniCourseCount >= depthThreshold {
            result.append(Achievement(id: "depth-\(depthThreshold)", title: "\(depthThreshold) mini-courses finished"))
        }

        let attempts = PointsSummary.recallAttempts(events)
        if attempts.count >= retentionMinimumAttempts,
           let accuracy = PointsSummary.recallAccuracy(events),
           accuracy >= retentionMinimumRate {
            result.append(Achievement(
                id: "retention-90",
                title: "90% recall across \(retentionMinimumAttempts)+ questions"
            ))
        }

        let activeDays = PointsSummary.activeDayCount(events, calendar: calendar)
        for threshold in consistencyThresholds where activeDays >= threshold {
            result.append(Achievement(id: "consistency-\(threshold)", title: "\(threshold) days of practice"))
        }

        return result
    }
}
