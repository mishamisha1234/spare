import Foundation

/// The single source of truth for gating. Pure functions over a value snapshot,
/// so gate decisions are testable without StoreKit, SwiftData, or a clock.
///
/// Free-tier counting is local and therefore spoofable. That is an accepted v1
/// tradeoff; there is no anti-tamper here by design.
public struct EntitlementSnapshot: Sendable, Equatable, Codable {
    public var tier: Tier
    public var freeLessonsUsedToday: Int
    public var lastFreeLessonDate: Date

    public init(
        tier: Tier = .free,
        freeLessonsUsedToday: Int = 0,
        lastFreeLessonDate: Date = .distantPast
    ) {
        self.tier = tier
        self.freeLessonsUsedToday = freeLessonsUsedToday
        self.lastFreeLessonDate = lastFreeLessonDate
    }

    public static let free = EntitlementSnapshot()
    public static let premium = EntitlementSnapshot(tier: .monthly)
}

public enum PaywallTrigger: Sendable, Equatable {
    /// Free user asked for a second lesson today.
    case dailyLimitReached
    /// Free user picked a window the free tier doesn't cover.
    case lockedWindow(TimeWindow)
    /// Free user tried to go deeper.
    case goDeeperLocked
}

public enum AccessDecision: Sendable, Equatable {
    case allowed
    case denied(PaywallTrigger)

    public var isAllowed: Bool { self == .allowed }

    public var trigger: PaywallTrigger? {
        if case .denied(let trigger) = self { return trigger }
        return nil
    }
}

public enum EntitlementRules {

    public static let freeLessonsPerDay = 1
    public static let freeLibraryLimit = 10

    /// Daily count, corrected for day rollover. A count recorded yesterday is
    /// not spent today.
    public static func effectiveLessonsUsedToday(
        _ snapshot: EntitlementSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        guard calendar.isDate(snapshot.lastFreeLessonDate, inSameDayAs: now) else { return 0 }
        return max(0, snapshot.freeLessonsUsedToday)
    }

    /// May this user start a lesson in this window right now?
    public static func canStartLesson(
        _ snapshot: EntitlementSnapshot,
        window: TimeWindow,
        now: Date,
        calendar: Calendar = .current
    ) -> AccessDecision {
        guard !snapshot.tier.isPremium else { return .allowed }

        // Window lock is checked first: it's the more specific, more
        // explicable reason to show the paywall.
        guard window.isFreeTierEligible else {
            return .denied(.lockedWindow(window))
        }
        let used = effectiveLessonsUsedToday(snapshot, now: now, calendar: calendar)
        guard used < freeLessonsPerDay else {
            return .denied(.dailyLimitReached)
        }
        return .allowed
    }

    /// Browsing suggestions for a locked window is allowed; committing isn't.
    /// The paywall fires when a lesson is requested, not when a card is tapped.
    public static func canBrowseSuggestions(_ snapshot: EntitlementSnapshot, window: TimeWindow) -> AccessDecision {
        guard !snapshot.tier.isPremium, !window.isFreeTierEligible else { return .allowed }
        return .denied(.lockedWindow(window))
    }

    public static func canGoDeeper(_ snapshot: EntitlementSnapshot) -> AccessDecision {
        snapshot.tier.isPremium ? .allowed : .denied(.goDeeperLocked)
    }

    /// Record a consumed lesson. Premium is untouched; free increments, resetting
    /// on a new calendar day.
    public static func consumingLesson(
        _ snapshot: EntitlementSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> EntitlementSnapshot {
        guard !snapshot.tier.isPremium else { return snapshot }
        var updated = snapshot
        let used = effectiveLessonsUsedToday(snapshot, now: now, calendar: calendar)
        updated.freeLessonsUsedToday = used + 1
        updated.lastFreeLessonDate = now
        return updated
    }

    /// How many library entries are visible. Free sees the most recent 10;
    /// older entries are hidden, never deleted, so upgrading restores them.
    public static func visibleLibraryCount(_ snapshot: EntitlementSnapshot, totalEntries: Int) -> Int {
        guard !snapshot.tier.isPremium else { return totalEntries }
        return min(totalEntries, freeLibraryLimit)
    }

    /// Entries hidden behind the free-tier library cap.
    public static func hiddenLibraryCount(_ snapshot: EntitlementSnapshot, totalEntries: Int) -> Int {
        max(0, totalEntries - visibleLibraryCount(snapshot, totalEntries: totalEntries))
    }

    /// Windows a user may choose without hitting the paywall.
    public static func availableWindows(_ snapshot: EntitlementSnapshot) -> [TimeWindow] {
        snapshot.tier.isPremium
            ? TimeWindow.allCases
            : TimeWindow.allCases.filter(\.isFreeTierEligible)
    }

    /// Applying a purchase result.
    public static func applying(tier: Tier, to snapshot: EntitlementSnapshot) -> EntitlementSnapshot {
        var updated = snapshot
        updated.tier = tier
        return updated
    }
}
