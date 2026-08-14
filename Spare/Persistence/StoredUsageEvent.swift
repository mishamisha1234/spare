import Foundation
import SwiftData
import SpareCore

/// SwiftData wrapper around a `UsageEvent`.
@Model
final class StoredUsageEvent {
    var kindRaw: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int
    var estimatedCostUSD: Double
    var occurredAt: Date

    init(
        kind: UsageKind,
        model: String,
        usage: TokenUsage,
        estimatedCostUSD: Double,
        occurredAt: Date
    ) {
        self.kindRaw = kind.rawValue
        self.model = model
        self.inputTokens = usage.inputTokens
        self.outputTokens = usage.outputTokens
        self.cacheCreationInputTokens = usage.cacheCreationInputTokens
        self.cacheReadInputTokens = usage.cacheReadInputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.occurredAt = occurredAt
    }

    convenience init(event: UsageEvent) {
        self.init(
            kind: event.kind,
            model: event.model,
            usage: event.usage,
            estimatedCostUSD: event.estimatedCostUSD,
            occurredAt: event.occurredAt
        )
    }

    var kind: UsageKind {
        get { UsageKind(rawValue: kindRaw) ?? .suggestions }
        set { kindRaw = newValue.rawValue }
    }

    var usage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            cacheReadInputTokens: cacheReadInputTokens
        )
    }

    /// Value copy, so `UsageSummary` can do the arithmetic without SwiftData.
    var event: UsageEvent {
        UsageEvent(
            kind: kind,
            model: model,
            usage: usage,
            occurredAt: occurredAt,
            estimatedCostUSD: estimatedCostUSD
        )
    }
}

/// Writes usage from whatever task the provider is running on.
///
/// `@ModelActor` gives it its own context bound to the shared container, which
/// is what makes it safe to call from a background generation task rather than
/// hopping to the main actor for every recorded call.
@ModelActor
actor UsageLedgerActor: UsageLedger {
    func record(_ event: UsageEvent) {
        modelContext.insert(StoredUsageEvent(event: event))
        try? modelContext.save()
    }
}
