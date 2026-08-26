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

    /// The trial mirror, as JSON.
    ///
    /// Persisted so a cold launch draws the right thing before the network
    /// answers. Without it a trialist opens the app to five locked circles
    /// that unlock a moment later, which reads as the trial having ended.
    ///
    /// One string rather than five columns because it is one value with one
    /// meaning, and because a defaulted property is the shape SwiftData's
    /// implicit migration handles without a plan. Never an authority: the
    /// server re-derives the same state before generating anything.
    var trialJSON: String = ""

    init(
        tier: Tier = .free,
        freeLessonsUsedToday: Int = 0,
        lastFreeLessonDate: Date = .distantPast,
        trial: TrialMirror = .eligible
    ) {
        self.tierRaw = tier.rawValue
        self.freeLessonsUsedToday = freeLessonsUsedToday
        self.lastFreeLessonDate = lastFreeLessonDate
        self.trialJSON = Self.encode(trial)
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

    /// A row written before the trial existed has no JSON, and a row written
    /// by a newer build might hold something this one cannot read. Both mean
    /// "no trial I can describe", which is `eligible` — a state that grants
    /// nothing and is corrected by the next status call.
    var trial: TrialMirror {
        get {
            guard let data = trialJSON.data(using: .utf8), !data.isEmpty else { return .eligible }
            return (try? JSONDecoder().decode(TrialMirror.self, from: data)) ?? .eligible
        }
        set { trialJSON = Self.encode(newValue) }
    }

    private static func encode(_ trial: TrialMirror) -> String {
        guard let data = try? JSONEncoder().encode(trial) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var snapshot: EntitlementSnapshot {
        EntitlementSnapshot(
            tier: tier,
            freeLessonsUsedToday: freeLessonsUsedToday,
            lastFreeLessonDate: lastFreeLessonDate,
            trial: trial
        )
    }

    func apply(_ snapshot: EntitlementSnapshot) {
        tier = snapshot.tier
        freeLessonsUsedToday = snapshot.freeLessonsUsedToday
        lastFreeLessonDate = snapshot.lastFreeLessonDate
        trial = snapshot.trial
    }
}
