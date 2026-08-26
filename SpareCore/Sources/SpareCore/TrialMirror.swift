import Foundation

/// The reverse trial, as the client is allowed to see it.
///
/// A *mirror*, and the name is the contract. Trial state lives on the server,
/// in the same Durable Object that meters the device, and the server re-checks
/// it atomically before generating anything. Nothing in this file can grant
/// access; it decides what the app draws.
///
/// That split is the same one the model routing already has. A client that
/// decided whether its own trial was live would be the same hole as a client
/// that picked its own model — and this one hands out Opus.
public enum TrialStatus: String, Codable, Sendable, CaseIterable {
    /// Never started. This device may still claim its one trial.
    case eligible
    /// Running, with lessons left.
    case active
    /// Started and finished — seven days elapsed, or ten lessons spent.
    case ended
}

/// What the server said about this device's trial, last time it was asked.
///
/// Decoded straight from `/v1/trial/status`, so the field names match the
/// wire. Dates arrive as milliseconds since the epoch because that is what
/// JavaScript's `Date.now()` produces; converting at the boundary keeps every
/// Swift caller in `Date`.
public struct TrialMirror: Sendable, Equatable, Codable {
    public var status: TrialStatus
    public var remainingLessons: Int
    public var remainingCourses: Int
    public var startedAt: Date?
    public var expiresAt: Date?

    public init(
        status: TrialStatus = .eligible,
        remainingLessons: Int = 0,
        remainingCourses: Int = 0,
        startedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.status = status
        self.remainingLessons = remainingLessons
        self.remainingCourses = remainingCourses
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }

    /// Nothing claimed yet.
    ///
    /// There is deliberately no `unavailable` beside this. A lookup that
    /// failed is not a state and must not be turned into one — see the type's
    /// own documentation, and `AllowanceStore`, which returns nil instead.
    public static let eligible = TrialMirror(status: .eligible)

    public var isActive: Bool { status == .active }

    /// The week ran out. Requires a start, and that is not belt and braces.
    ///
    /// `status == .ended` alone was the whole of this check once, and it was
    /// wrong in the worst available way: a fabricated `ended` — from a failed
    /// lookup, or from a status this build could not parse — satisfied it, and
    /// the day-7 summary fired for somebody who had never had a trial. With no
    /// `startedAt` to count from it then summed their entire library and told
    /// them it was their week. Plausible, specific, and invented.
    ///
    /// A trial that ended has a start. Anything claiming otherwise is noise.
    public var hasEnded: Bool { status == .ended && startedAt != nil }

    /// Whole days left, rounded up, so the last part-day reads as "1 day left"
    /// rather than "0".
    public func daysRemaining(now: Date) -> Int {
        guard status == .active, let expiresAt, expiresAt > now else { return 0 }
        return Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.up))
    }

    /// How far through the week the reader is, zero-based. Day 0 is the day
    /// the trial started; the nudge fires on day 4.
    public func dayIndex(now: Date) -> Int? {
        guard let startedAt, now >= startedAt else { return nil }
        return Int(now.timeIntervalSince(startedAt) / 86_400)
    }

    private enum CodingKeys: String, CodingKey {
        case status, remainingLessons, remainingCourses, startedAt, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognised status throws rather than falling back.
        //
        // It fell back to `ended` once, on the reasoning that a server growing
        // a fourth state must not brick an older client. That reasoning was
        // backwards: `ended` is not a neutral reading of "I don't know", it is
        // the reading that triggers the day-7 summary. Throwing here means the
        // caller gets nil, which is what "I don't know" actually looks like,
        // and the app keeps whatever it already had.
        let raw = try container.decode(String.self, forKey: .status)
        guard let status = TrialStatus(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .status, in: container,
                debugDescription: "unrecognised trial status \"\(raw)\""
            )
        }
        self.status = status
        remainingLessons = try container.decodeIfPresent(Int.self, forKey: .remainingLessons) ?? 0
        remainingCourses = try container.decodeIfPresent(Int.self, forKey: .remainingCourses) ?? 0
        startedAt = Self.date(try container.decodeIfPresent(Double.self, forKey: .startedAt))
        expiresAt = Self.date(try container.decodeIfPresent(Double.self, forKey: .expiresAt))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(remainingLessons, forKey: .remainingLessons)
        try container.encode(remainingCourses, forKey: .remainingCourses)
        try container.encodeIfPresent(startedAt.map(Self.milliseconds), forKey: .startedAt)
        try container.encodeIfPresent(expiresAt.map(Self.milliseconds), forKey: .expiresAt)
    }

    private static func date(_ milliseconds: Double?) -> Date? {
        guard let milliseconds else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }
}

/// The result of asking for a trial.
public struct TrialStartResult: Sendable, Equatable {
    public var started: Bool
    /// `alreadyUsed` or `alreadySubscribed` when `started` is false.
    public var reason: String?
    public var trial: TrialMirror

    public init(started: Bool, reason: String? = nil, trial: TrialMirror) {
        self.started = started
        self.reason = reason
        self.trial = trial
    }
}
