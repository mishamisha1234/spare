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
    /// own documentation, and `TrialStore`, which returns nil instead.
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

/// Everything the app needs from the trial, behind one protocol.
///
/// Same shape and same reasoning as `PurchaseStore`: the real implementation
/// talks to the proxy, and a stub drives the trial screens in UI tests and
/// previews. CI can then screenshot the day-4 nudge and the day-7 summary
/// without a network, a clock, or a seven-day wait.
/// Both methods answer `nil` for "I could not ask", which is the whole of the
/// contract that matters. A failed read is not an answer: the caller keeps
/// whatever it already had rather than being handed a state nobody reported.
public protocol TrialStore: Sendable {
    /// Claims this device's one trial. Idempotent server-side, so calling it
    /// twice cannot extend anything. Nil when the proxy could not be reached —
    /// distinct from a result saying the trial was refused.
    func start() async -> TrialStartResult?
    /// Re-reads the mirror. Nil when the proxy could not be reached.
    func status() async -> TrialMirror?
}

/// The real store. One small POST per call, to the same proxy as everything
/// else.
///
/// Every generation response already carries an `x-spare-trial` header with
/// the current mirror, which would save this round trip. It is not read here:
/// lesson generation is the streaming path, and `HTTPTransport.stream` yields
/// bytes with no response metadata at all — surfacing headers would mean
/// changing the transport protocol on both paths for one caller. Refreshing
/// after a lesson finishes costs one small request at exactly the moment the
/// count changes, and the header stays useful to anything that can read it.
public struct ProxyTrialStore: TrialStore {
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let deviceID: String
    private let receipt: @Sendable () async -> String?

    public init(
        transport: any HTTPTransport,
        baseURL: URL,
        deviceID: String,
        receipt: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.receipt = receipt
    }

    public func start() async -> TrialStartResult? {
        guard let body = await post("/v1/trial/start"),
              let root = try? JSONDecoder().decode(JSONValue.self, from: body),
              let trial = try? JSONDecoder().decode(
                  TrialMirror.self, from: nested(body, key: "trial")
              )
        else { return nil }

        return TrialStartResult(
            started: root["started"]?.boolValue ?? false,
            reason: root["reason"]?.stringValue,
            trial: trial
        )
    }

    public func status() async -> TrialMirror? {
        guard let body = await post("/v1/trial/status") else { return nil }
        return try? JSONDecoder().decode(TrialMirror.self, from: body)
    }

    /// The `trial` object out of a start response, as its own JSON document.
    private func nested(_ body: Data, key: String) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = root[key],
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return Data() }
        return data
    }

    private func post(_ path: String) async -> Data? {
        // `URL(string:relativeTo:)`, the same as `ProxyRoute`. A base URL with
        // a path component and `appendingPathComponent` disagree about where
        // the slash goes, and this way both call sites are wrong or right
        // together.
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }

        var payload: [String: JSONValue] = [:]
        // Sent so the server can refuse to burn a subscriber's eligibility
        // rather than spending it on somebody who is already paying.
        if let receipt = await receipt(), !receipt.isEmpty {
            payload["receipt"] = .string(receipt)
        }

        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "content-type": "application/json",
                "x-spare-device": deviceID,
            ],
            body: try? JSONEncoder().encode(JSONValue.object(payload)),
            timeout: 20
        )

        guard let response = try? await transport.send(request), response.isSuccess else { return nil }
        return response.body
    }
}

/// Deterministic stand-in for UI tests and previews.
///
/// Starts from whatever state the caller names, so a walkthrough can begin on
/// day 4 or the morning after expiry without waiting or faking a clock.
public actor StubTrialStore: TrialStore {
    private var mirror: TrialMirror

    public init(_ mirror: TrialMirror = .eligible) {
        self.mirror = mirror
    }

    public func start() async -> TrialStartResult? {
        guard mirror.status == .eligible else {
            return TrialStartResult(started: false, reason: "alreadyUsed", trial: mirror)
        }
        let now = Date()
        mirror = TrialMirror(
            status: .active,
            remainingLessons: TrialLimits.lessons,
            remainingCourses: TrialLimits.courses,
            startedAt: now,
            expiresAt: now.addingTimeInterval(TrialLimits.duration)
        )
        return TrialStartResult(started: true, trial: mirror)
    }

    public func status() async -> TrialMirror? { mirror }
}

/// A proxy that cannot be reached.
///
/// Exists so the screenshot walkthrough can photograph what a device with no
/// network sees, which is the case that produced the worst bug in this
/// feature: an unreachable server used to read as "your free week is over",
/// and the day-7 summary fired for somebody who had never had one.
public struct UnreachableTrialStore: TrialStore {
    public init() {}
    public func start() async -> TrialStartResult? { nil }
    public func status() async -> TrialMirror? { nil }
}

/// The trial's shape, mirroring `TRIAL_LESSONS` / `TRIAL_COURSES` /
/// `TRIAL_DAYS` in `server/src/limits.ts`.
///
/// The server is the authority on all three; these exist so the *copy* can
/// state them without a round trip, and because a disclosed cap has to be
/// stated before the reader has one to read. Kept in step by
/// `TrialCopyTests`, the same way the free tier's numbers are.
public enum TrialLimits {
    public static let lessons = 10
    public static let courses = 2
    public static let days = 7
    public static let duration: TimeInterval = Double(days) * 86_400
}
