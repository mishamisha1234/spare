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
    /// Free user tapped the post-lesson test.
    case postLessonTestLocked
}

/// A limit that applies to someone who is *already paying*. Distinct from a
/// `PaywallTrigger` on purpose: showing a paywall to a subscriber who hit a
/// fair-use cap would be both useless and insulting, so the two can never be
/// confused at a call site.
public enum UsageCap: Sendable, Equatable {
    case miniCoursesThisMonth(used: Int, cap: Int)
}

public enum AccessDecision: Sendable, Equatable {
    case allowed
    case denied(PaywallTrigger)
    case capped(UsageCap)

    public var isAllowed: Bool { self == .allowed }

    /// Non-nil only for a paywall denial — a `capped` decision deliberately
    /// yields no trigger, so "show the paywall for any denial" can't compile
    /// into existence.
    public var trigger: PaywallTrigger? {
        if case .denied(let trigger) = self { return trigger }
        return nil
    }

    public var cap: UsageCap? {
        if case .capped(let cap) = self { return cap }
        return nil
    }
}

public enum EntitlementRules {

    public static let freeLessonsPerDay = 1
    public static let freeLibraryLimit = 10
    /// Fair-use ceiling on the most expensive thing to generate. A course is
    /// an outline call plus two calls per chapter; "unlimited" on that line
    /// would mean an unbounded per-user cost. Surfaced honestly in Settings
    /// rather than discovered at the moment it bites.
    ///
    /// Raised from 8 to 12 when courses went from 45 minutes to 30: at 4
    /// chapters and ~6,200 words instead of 6 and ~8,000, a course costs
    /// roughly a third less to generate, so 12 of the new ones is cheaper
    /// than 8 of the old.
    public static let premiumMiniCoursesPerMonth = 12

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

    /// Mini-courses started in the calendar month containing `now`.
    ///
    /// Derived from actual start dates rather than a stored counter, for the
    /// same reason the points ledger keeps every event: a count that is
    /// recomputed can't drift out of sync with the thing it counts, and
    /// month rollover needs no scheduled reset.
    public static func miniCoursesUsed(
        startDates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        startDates.filter { calendar.isDate($0, equalTo: now, toGranularity: .month) }.count
    }

    public static func miniCoursesRemaining(
        startDates: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let used = miniCoursesUsed(startDates: startDates, now: now, calendar: calendar)
        return max(0, premiumMiniCoursesPerMonth - used)
    }

    /// May this user start a lesson in this window right now?
    ///
    /// `miniCourseStartDates` defaults to empty, which reads as "no
    /// mini-courses started" — correct for every caller that isn't asking
    /// about the chaptered window.
    public static func canStartLesson(
        _ snapshot: EntitlementSnapshot,
        window: TimeWindow,
        miniCourseStartDates: [Date] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> AccessDecision {
        guard !snapshot.tier.hasPremiumAccess else {
            // The one limit that applies to paying users. Not a paywall.
            guard window.format.isChaptered else { return .allowed }
            let used = miniCoursesUsed(startDates: miniCourseStartDates, now: now, calendar: calendar)
            guard used < premiumMiniCoursesPerMonth else {
                return .capped(.miniCoursesThisMonth(used: used, cap: premiumMiniCoursesPerMonth))
            }
            return .allowed
        }

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

    /// The immediate 3-question test after a lesson. Premium only — but it is
    /// shown to free users as a visibly locked row that opens the paywall,
    /// never hidden, since a feature nobody can see sells nothing.
    public static func canTakePostLessonTest(_ snapshot: EntitlementSnapshot) -> AccessDecision {
        snapshot.tier.hasPremiumAccess ? .allowed : .denied(.postLessonTestLocked)
    }

    /// Browsing suggestions for a locked window is allowed; committing isn't.
    /// The paywall fires when a lesson is requested, not when a card is tapped.
    public static func canBrowseSuggestions(_ snapshot: EntitlementSnapshot, window: TimeWindow) -> AccessDecision {
        guard !snapshot.tier.hasPremiumAccess, !window.isFreeTierEligible else { return .allowed }
        return .denied(.lockedWindow(window))
    }

    public static func canGoDeeper(_ snapshot: EntitlementSnapshot) -> AccessDecision {
        snapshot.tier.hasPremiumAccess ? .allowed : .denied(.goDeeperLocked)
    }

    /// Record a consumed lesson. Premium is untouched; free increments, resetting
    /// on a new calendar day.
    public static func consumingLesson(
        _ snapshot: EntitlementSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> EntitlementSnapshot {
        guard !snapshot.tier.hasPremiumAccess else { return snapshot }
        var updated = snapshot
        let used = effectiveLessonsUsedToday(snapshot, now: now, calendar: calendar)
        updated.freeLessonsUsedToday = used + 1
        updated.lastFreeLessonDate = now
        return updated
    }

    /// How many library entries are visible. Free sees the most recent 10;
    /// older entries are hidden, never deleted, so upgrading restores them.
    public static func visibleLibraryCount(_ snapshot: EntitlementSnapshot, totalEntries: Int) -> Int {
        guard !snapshot.tier.hasPremiumAccess else { return totalEntries }
        return min(totalEntries, freeLibraryLimit)
    }

    /// Entries hidden behind the free-tier library cap.
    public static func hiddenLibraryCount(_ snapshot: EntitlementSnapshot, totalEntries: Int) -> Int {
        max(0, totalEntries - visibleLibraryCount(snapshot, totalEntries: totalEntries))
    }

    /// Windows a user may choose without hitting the paywall.
    public static func availableWindows(_ snapshot: EntitlementSnapshot) -> [TimeWindow] {
        snapshot.tier.hasPremiumAccess
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
