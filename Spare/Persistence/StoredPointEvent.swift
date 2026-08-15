import Foundation
import SwiftData
import SpareCore

/// SwiftData wrapper around a `PointEvent`. Append-only like the value type
/// it wraps: nothing in this file ever mutates or deletes a row — totals,
/// levels, and achievements are always recomputed from the full set.
@Model
final class StoredPointEvent {
    var occurredAt: Date
    var kindRaw: String
    var amount: Int
    var sourceID: String

    init(
        occurredAt: Date,
        kind: PointEventKind,
        amount: Int,
        sourceID: String
    ) {
        self.occurredAt = occurredAt
        self.kindRaw = kind.rawValue
        self.amount = amount
        self.sourceID = sourceID
    }

    convenience init(event: PointEvent) {
        self.init(
            occurredAt: event.occurredAt,
            kind: event.kind,
            amount: event.amount,
            sourceID: event.sourceID
        )
    }

    var kind: PointEventKind {
        get { PointEventKind(rawValue: kindRaw) ?? .lessonCompleted }
        set { kindRaw = newValue.rawValue }
    }

    /// Value copy, so `PointsSummary` and `Achievements` can do their
    /// arithmetic without SwiftData.
    var event: PointEvent {
        PointEvent(occurredAt: occurredAt, kind: kind, amount: amount, sourceID: sourceID)
    }
}

/// Writes points from whatever task earned them.
///
/// `@ModelActor` gives it its own context bound to the shared container —
/// the same reason `UsageLedgerActor` is one — so recording a point event
/// from a background task never needs a hop to the main actor.
@ModelActor
actor PointsLedgerActor: PointsLedger {
    func record(_ event: PointEvent) {
        modelContext.insert(StoredPointEvent(event: event))
        try? modelContext.save()
    }
}
