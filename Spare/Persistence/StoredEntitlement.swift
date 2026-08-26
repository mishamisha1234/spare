import Foundation
import SwiftData
import SpareCore

/// SwiftData wrapper around `EntitlementSnapshot`.
///
/// All gate decisions are made by `EntitlementRules` against the value copy —
/// there are no `if hasPremiumAccess` checks scattered through views.
@Model
final class StoredEntitlement {
    var tierRaw: String
    var freeLessonsUsedToday: Int
    var lastFreeLessonDate: Date

    init(
        tier: Tier = .free,
        freeLessonsUsedToday: Int = 0,
        lastFreeLessonDate: Date = .distantPast
    ) {
        self.tierRaw = tier.rawValue
        self.freeLessonsUsedToday = freeLessonsUsedToday
        self.lastFreeLessonDate = lastFreeLessonDate
    }

    /// `Tier.stored(rawValue:)` rather than `Tier(rawValue:)`.
    ///
    /// The lifetime product was withdrawn, and a plain `init(rawValue:)`
    /// returns nil for a row still holding it — which the `?? .free` below
    /// would turn into a silent downgrade on the next launch. The same trap
    /// `TimeWindow` already has a table for.
    var tier: Tier {
        get { Tier.stored(rawValue: tierRaw) ?? .free }
        set { tierRaw = newValue.rawValue }
    }

    var snapshot: EntitlementSnapshot {
        EntitlementSnapshot(
            tier: tier,
            freeLessonsUsedToday: freeLessonsUsedToday,
            lastFreeLessonDate: lastFreeLessonDate
        )
    }

    func apply(_ snapshot: EntitlementSnapshot) {
        tier = snapshot.tier
        freeLessonsUsedToday = snapshot.freeLessonsUsedToday
        lastFreeLessonDate = snapshot.lastFreeLessonDate
    }
}
