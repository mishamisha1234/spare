import Foundation

/// What earned — or, for a full picture, failed to earn — points. Every
/// recall attempt is logged, correct or not, at 0 points when incorrect, so
/// retention rate is always computable straight from the ledger rather than
/// needing a separate pass/fail counter kept in sync with it by hand.
public enum PointEventKind: String, Codable, Sendable, CaseIterable {
    case lessonCompleted
    case recallCorrect
    case recallIncorrect
    case postLessonTestCorrect
    case postLessonTestIncorrect

    public var label: String {
        switch self {
        case .lessonCompleted: "Lesson completed"
        case .recallCorrect: "Recall — correct"
        case .recallIncorrect: "Recall — incorrect"
        case .postLessonTestCorrect: "Post-lesson test — correct"
        case .postLessonTestIncorrect: "Post-lesson test — incorrect"
        }
    }
}

/// One entry in the points ledger. Append-only: a `PointEvent` is never
/// mutated or deleted once recorded, so a total is always the sum of the full
/// history, not a running counter that can silently drift out of sync with it.
public struct PointEvent: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var occurredAt: Date
    public var kind: PointEventKind
    public var amount: Int
    /// What this event is about — a lesson, a recall item, a test. A plain
    /// string rather than a UUID so it can name whatever the source turns
    /// out to be, without the ledger needing to know its type.
    public var sourceID: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        kind: PointEventKind,
        amount: Int,
        sourceID: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.amount = amount
        self.sourceID = sourceID
    }
}

/// Where points get written. The app persists to SwiftData; tests keep it in
/// memory. Mirrors `UsageLedger`'s shape.
public protocol PointsLedger: Sendable {
    func record(_ event: PointEvent) async
}

/// Discards everything — the default so nothing is ever *required* to be
/// wired to storage just to run.
public struct NoopPointsLedger: PointsLedger {
    public init() {}
    public func record(_ event: PointEvent) async {}
}

public actor InMemoryPointsLedger: PointsLedger {
    public private(set) var events: [PointEvent] = []

    public init() {}

    public func record(_ event: PointEvent) {
        events.append(event)
    }
}

/// Pure arithmetic over the ledger — total, by kind, retention rate,
/// consistency. Kept separate from the storage layer so it is testable
/// without SwiftData, and reusable by both the stats screen and the
/// achievement definitions.
public enum PointsSummary {

    public static func total(_ events: [PointEvent]) -> Int {
        events.reduce(0) { $0 + $1.amount }
    }

    public static func byKind(_ events: [PointEvent]) -> [PointEventKind: Int] {
        var totals: [PointEventKind: Int] = [:]
        for event in events { totals[event.kind, default: 0] += event.amount }
        return totals
    }

    /// Every recall attempt, correct or not, from either the daily question
    /// or the immediate post-lesson test.
    public static func recallAttempts(_ events: [PointEvent]) -> [PointEvent] {
        events.filter {
            switch $0.kind {
            case .recallCorrect, .recallIncorrect, .postLessonTestCorrect, .postLessonTestIncorrect:
                return true
            case .lessonCompleted:
                return false
            }
        }
    }

    /// `nil` when there is no attempt to measure yet, rather than a
    /// misleading 0%.
    public static func recallAccuracy(_ events: [PointEvent]) -> Double? {
        let attempts = recallAttempts(events)
        guard !attempts.isEmpty else { return nil }
        let correct = attempts.filter { $0.kind == .recallCorrect || $0.kind == .postLessonTestCorrect }.count
        return Double(correct) / Double(attempts.count)
    }

    /// Distinct calendar days with at least one recorded event — the basis
    /// for the consistency achievements. Deliberately not a "don't break the
    /// chain" unbroken streak: losing all progress toward a 365-day
    /// achievement over one missed day runs against the app's calm,
    /// low-pressure feel, so this counts cumulative days of engagement
    /// instead.
    public static func activeDayCount(_ events: [PointEvent], calendar: Calendar = .current) -> Int {
        Set(events.map { calendar.startOfDay(for: $0.occurredAt) }).count
    }
}
