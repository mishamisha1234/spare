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
    /// The server's last word on this device's trial.
    ///
    /// Display and affordances only. `tier == .trialing` is derived from it,
    /// and the server re-derives the same thing from its own copy before
    /// generating anything, so a mirror that is stale or edited costs a
    /// misdrawn circle rather than a lesson.
    public var trial: TrialMirror
    /// This month's remaining premium allowance, when the server has said.
    ///
    /// Deliberately not persisted. A stale figure from a previous session or a
    /// previous month would lock a subscriber out of lengths they can have,
    /// and the whole point of a mirror is that being briefly wrong costs a
    /// misdrawn circle rather than a lesson. Nil means "no cap enforced here
    /// yet" -- the server still enforces it.
    public var premiumAllowance: PremiumAllowance?

    public init(
        tier: Tier = .free,
        freeLessonsUsedToday: Int = 0,
        lastFreeLessonDate: Date = .distantPast,
        trial: TrialMirror = .eligible,
        premiumAllowance: PremiumAllowance? = nil
    ) {
        self.tier = tier
        self.freeLessonsUsedToday = freeLessonsUsedToday
        self.lastFreeLessonDate = lastFreeLessonDate
        self.trial = trial
        self.premiumAllowance = premiumAllowance
    }

    public static let free = EntitlementSnapshot()
    public static let premium = EntitlementSnapshot(tier: .monthly)

    /// A trial with everything still to spend.
    public static let trialing = EntitlementSnapshot(
        tier: .trialing,
        trial: TrialMirror(
            status: .active,
            remainingLessons: TrialLimits.lessons,
            remainingCourses: TrialLimits.courses
        )
    )

    private enum CodingKeys: String, CodingKey {
        case tier, freeLessonsUsedToday, lastFreeLessonDate, trial, premiumAllowance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try container.decode(Tier.self, forKey: .tier)
        freeLessonsUsedToday = try container.decode(Int.self, forKey: .freeLessonsUsedToday)
        lastFreeLessonDate = try container.decode(Date.self, forKey: .lastFreeLessonDate)
        // Absent in anything written before the trial existed.
        trial = try container.decodeIfPresent(TrialMirror.self, forKey: .trial) ?? .eligible
        premiumAllowance = try container.decodeIfPresent(
            PremiumAllowance.self, forKey: .premiumAllowance
        )
    }
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
    /// The first lesson has just been finished.
    ///
    /// Not a refusal -- nothing was denied. It is the one paywall the reader
    /// did not ask for, and the ordering rule says it is also the earliest
    /// one allowed: shown before the product has demonstrated itself, a price
    /// reads as a shakedown from someone who has proved nothing.
    case firstLessonComplete
    /// The free week is over. Distinct from every trigger above because it
    /// opens the day-7 summary rather than the ordinary paywall: the ask is
    /// about keeping what the reader built, not about a length they just
    /// tapped.
    case trialEnded
}

/// A limit that applies to someone who is *already paying*. Distinct from a
/// `PaywallTrigger` on purpose: showing a paywall to a subscriber who hit a
/// fair-use cap would be both useless and insulting, so the two can never be
/// confused at a call site.
/// A limit that is *not* an invitation to buy.
///
/// Renamed in spirit when the trial landed: the original comment said "someone
/// who is already paying", which a trialist is not. What the two cases share
/// is that showing a paywall would be the wrong response — a subscriber who
/// hit a fair-use cap cannot buy their way out of it, and a trialist who spent
/// both course slots still has most of a free week left and should be told so
/// rather than sold to.
public enum UsageCap: Sendable, Equatable {
    case miniCoursesThisMonth(used: Int, cap: Int)
    case lessonsThisMonth(used: Int, cap: Int)
    case trialCoursesThisWeek(used: Int, cap: Int)
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
    /// Fair-use ceiling on the most expensive thing to generate. A course is
    /// an outline call plus two calls per chapter; "unlimited" on that line
    /// would mean an unbounded per-user cost. Surfaced honestly in Settings
    /// rather than discovered at the moment it bites.
    ///
    /// Back to 8, from 12, before there is anybody to lower it on.
    ///
    /// Not because 12 was expensive -- with a lesson cap in place, cutting
    /// four course slots saves about $3.50 of worst case, because the freed
    /// slots become four more 15-minute lessons at $0.53 rather than
    /// vanishing. The reason is direction: a disclosed cap can be raised
    /// whenever usage says so, and cannot be lowered on existing subscribers
    /// without a material-change notice. Every number here is free exactly
    /// until the first purchase, and 12 was chosen with no data at all.
    public static let premiumMiniCoursesPerMonth = 8

    /// The monthly ceiling on premium lessons of any length.
    ///
    /// A course counts against this *and* against the mini-course cap: it is
    /// one of the 50 and one of the 8, the same way a trial course is one of
    /// the 10 and one of the 2.
    ///
    /// Fifty is chosen to be a number no honest daily reader meets. Thirty-one
    /// days at one a day is 31; fifty tolerates a reader averaging 1.6 a day
    /// every day of the month. What it bounds is the tail -- and only
    /// together with the course cap, since a course is worth roughly three
    /// 15-minute lessons.
    ///
    /// It does not fix the unit economics of a daily 15-minute reader, and
    /// nothing in this range would: that reader costs ~$15.90 a month against
    /// $6.30 net on the annual plan, and the shared premium cache is what
    /// closes that gap, not this.
    public static let premiumLessonsPerMonth = 50

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

    // `miniCoursesUsed` and `miniCoursesRemaining` counted library rows in the
    // current month. They are deleted rather than kept, because the server
    // counts *charges* -- cache hits included, abandoned lessons included --
    // and the two answers drift. Nothing noticed while the cap was 12 and
    // unreachable; a remaining count printed on the paywall would have.
    //
    // The month's figures now arrive in `EntitlementSnapshot.premium`, from
    // the same object that will refuse the request.

    /// May this user start a lesson in this window right now?
    public static func canStartLesson(
        _ snapshot: EntitlementSnapshot,
        window: TimeWindow,
        now: Date,
        calendar: Calendar = .current
    ) -> AccessDecision {
        // The trial's own two ceilings, mirroring the server's. Checked before
        // the general premium branch because a trialist is premium *within a
        // budget*, and the budget is the part the reader has to be able to see.
        if snapshot.tier == .trialing {
            guard snapshot.trial.remainingLessons > 0 else {
                return .denied(.trialEnded)
            }
            guard window.format.isChaptered else { return .allowed }
            guard snapshot.trial.remainingCourses > 0 else {
                return .capped(.trialCoursesThisWeek(
                    used: max(0, TrialLimits.courses - snapshot.trial.remainingCourses),
                    cap: TrialLimits.courses
                ))
            }
            return .allowed
        }

        guard !snapshot.tier.hasPremiumAccess else {
            // The two limits that apply to paying users. Neither is a paywall:
            // a subscriber at a fair-use cap cannot buy their way out of it.
            //
            // Both come from the server's own count, mirrored into the
            // snapshot. There is no local derivation any more -- the previous
            // one counted library rows while the server counted charges, and
            // the two answers drifted. A cap nobody reached hid that; a
            // disclosed remaining count would not.
            guard let allowance = snapshot.premiumAllowance else { return .allowed }

            if window.format.isChaptered, allowance.coursesRemaining <= 0 {
                return .capped(.miniCoursesThisMonth(
                    used: max(0, premiumMiniCoursesPerMonth - allowance.coursesRemaining),
                    cap: premiumMiniCoursesPerMonth
                ))
            }
            guard allowance.lessonsRemaining > 0 else {
                return .capped(.lessonsThisMonth(
                    used: max(0, premiumLessonsPerMonth - allowance.lessonsRemaining),
                    cap: premiumLessonsPerMonth
                ))
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

    // The free tier used to see only its most recent 10 library entries,
    // through `visibleLibraryCount` / `hiddenLibraryCount` / `freeLibraryLimit`.
    // All three are gone rather than made permissive, because a cap that
    // returns `totalEntries` is a cap somebody will re-tighten.
    //
    // Two reasons, and the second is the load-bearing one:
    //
    //   1. The library is never truncated for anybody. No cap, no deletion.
    //   2. The whole selling model is now loss aversion at the end of a free
    //      week -- deciding whether to give up a 17-item library. Truncating
    //      that library at the moment the trial ends takes away the thing the
    //      reader is being asked to keep. The mechanism would eat itself.
    //
    // What the free tier limits is how many *new* entries arrive: one lesson
    // a day. What it does not limit is reading back what is already there.

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
