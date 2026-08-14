import Foundation

/// Which call produced a charge. Every API call the app makes is one of these,
/// so a monthly bill can be explained rather than just totalled.
public enum UsageKind: String, Codable, Sendable, CaseIterable {
    case suggestions
    case courseOutline
    case lessonDraft
    case lessonRevision
    case chapterDraft
    case chapterRevision
    case recallQuestion
    case goDeeperDraft
    case goDeeperRevision

    public var label: String {
        switch self {
        case .suggestions: "Topic suggestions"
        case .courseOutline: "Course outline"
        case .lessonDraft: "Lesson draft"
        case .lessonRevision: "Lesson revision"
        case .chapterDraft: "Chapter draft"
        case .chapterRevision: "Chapter revision"
        case .recallQuestion: "Recall question"
        case .goDeeperDraft: "Go deeper draft"
        case .goDeeperRevision: "Go deeper revision"
        }
    }
}

/// One billed API call.
public struct UsageEvent: Sendable, Codable, Equatable {
    public var kind: UsageKind
    public var model: String
    public var usage: TokenUsage
    public var estimatedCostUSD: Double
    public var occurredAt: Date

    public init(
        kind: UsageKind,
        model: String,
        usage: TokenUsage,
        occurredAt: Date,
        estimatedCostUSD: Double? = nil
    ) {
        self.kind = kind
        self.model = model
        self.usage = usage
        self.occurredAt = occurredAt
        self.estimatedCostUSD = estimatedCostUSD ?? CostEstimator.cost(of: usage)
    }
}

/// Where usage gets written. The app persists to SwiftData; tests keep it in
/// memory; previews discard it.
public protocol UsageLedger: Sendable {
    func record(_ event: UsageEvent) async
}

/// Discards everything — the default so a provider is never *required* to be
/// wired to storage just to run.
public struct NoopUsageLedger: UsageLedger {
    public init() {}
    public func record(_ event: UsageEvent) async {}
}

public actor InMemoryUsageLedger: UsageLedger {
    public private(set) var events: [UsageEvent] = []

    public init() {}

    public func record(_ event: UsageEvent) {
        events.append(event)
    }

    public func events(ofKind kind: UsageKind) -> [UsageEvent] {
        events.filter { $0.kind == kind }
    }
}

/// Pure aggregation over recorded events. Settings shows the monthly figure;
/// keeping the arithmetic here means it is testable without SwiftData.
public enum UsageSummary {

    public static func total(_ events: [UsageEvent]) -> Double {
        events.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    /// Total for the calendar month containing `date`.
    public static func monthTotal(
        _ events: [UsageEvent],
        containing date: Date,
        calendar: Calendar = .current
    ) -> Double {
        total(events.filter {
            calendar.isDate($0.occurredAt, equalTo: date, toGranularity: .month)
        })
    }

    public static func byKind(_ events: [UsageEvent]) -> [UsageKind: Double] {
        var totals: [UsageKind: Double] = [:]
        for event in events {
            totals[event.kind, default: 0] += event.estimatedCostUSD
        }
        return totals
    }

    public static func totalTokens(_ events: [UsageEvent]) -> TokenUsage {
        events.reduce(TokenUsage()) { $0 + $1.usage }
    }
}
