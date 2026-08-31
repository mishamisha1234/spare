import Foundation

/// The trial's shape, mirroring `TRIAL_LESSONS` / `TRIAL_COURSES` /
/// `TRIAL_DAYS` in `server/src/limits.ts`.
///
/// The server is the authority on all three; these exist so the *copy* can
/// state them without a round trip, and because a disclosed cap has to be
/// stated before the reader has one to read. Kept in step by `TrialCopyTests`,
/// the same way the free tier's numbers are.
public enum TrialLimits {
    public static let lessons = 10
    public static let courses = 2
    public static let days = 7
    public static let duration: TimeInterval = Double(days) * 86_400
}

/// What a paying subscriber has left this calendar month.
///
/// Comes from the server and nowhere else. There was a local derivation once —
/// mini-courses counted from library rows — and it was wrong in a way nothing
/// noticed: the server counts *charges*, including cache hits and lessons
/// started and abandoned, while the library counts finished rows. The two
/// answers drift. That was survivable while the cap was 12 and nobody reached
/// it. It stops being survivable the moment a remaining count is printed on
/// the paywall, because then a reader is told "6 left" and refused at 4.
public struct PremiumAllowance: Sendable, Equatable, Codable {
    public var lessonsRemaining: Int
    public var coursesRemaining: Int

    public init(lessonsRemaining: Int, coursesRemaining: Int) {
        self.lessonsRemaining = lessonsRemaining
        self.coursesRemaining = coursesRemaining
    }
}

/// Everything the server will tell a device about what it may still do.
public struct AllowanceMirror: Sendable, Equatable, Codable {
    public var trial: TrialMirror
    /// Present only for a subscriber. A free or trialing device has no monthly
    /// premium allowance, and reporting zeros for one would read as a cap
    /// they had exhausted rather than a cap that does not apply to them.
    public var premium: PremiumAllowance?

    public init(trial: TrialMirror, premium: PremiumAllowance? = nil) {
        self.trial = trial
        self.premium = premium
    }
}

/// Three states, because two is what caused the bug this codebase now has a
/// standing rule about.
///
/// "Not asked yet" and "asked and could not be reached" look identical if you
/// only model presence and absence — and they need different copy. The first
/// is the ordinary first second of a launch, where saying *"check your
/// connection"* would be a false alarm for every reader every time. The second
/// is a real failure, and the *fact* of it is the one thing worth telling them,
/// because it is the part they can act on.
public enum AllowanceState: Sendable, Equatable {
    /// No answer yet this session. Show the caps, no counts, no alarm.
    case unknown
    /// Asked, and the proxy could not be reached. Show the caps, no counts,
    /// and say so.
    case unavailable
    case known(AllowanceMirror)

    public var mirror: AllowanceMirror? {
        if case .known(let mirror) = self { return mirror }
        return nil
    }

    public var premium: PremiumAllowance? { mirror?.premium }
}

/// Everything the app needs about its own allowance, behind one protocol.
///
/// Same shape and same reasoning as `PurchaseStore`: the real implementation
/// talks to the proxy, and a stub drives the trial screens in UI tests and
/// previews. CI can then screenshot the day-4 nudge and the day-7 summary
/// without a network, a clock, or a seven-day wait.
///
/// Both methods answer `nil` for "I could not ask", which is the whole of the
/// contract that matters. A failed read is not an answer: the caller keeps
/// whatever it already had rather than being handed a state nobody reported.
/// See the standing rule in README.md.
public protocol AllowanceStore: Sendable {
    /// Claims this device's one trial. Idempotent server-side, so calling it
    /// twice cannot extend anything. Nil when the proxy could not be reached —
    /// distinct from a result saying the trial was refused, which is an answer.
    func startTrial() async -> TrialStartResult?
    /// Reads the trial and, for a subscriber, the month's remaining premium
    /// allowance. Nil when the proxy could not be reached.
    func read() async -> AllowanceMirror?
}

/// The real store. One small POST per call, to the same proxy as everything
/// else.
///
/// Every generation response already carries an `x-spare-trial` header with
/// the current trial mirror, which would save a round trip. It is not read
/// here: lesson generation is the streaming path, and `HTTPTransport.stream`
/// yields bytes with no response metadata at all — surfacing headers would
/// mean changing the transport protocol on both paths for one caller.
/// Refreshing after a lesson finishes costs one small request at exactly the
/// moment the counts change.
public struct ProxyAllowanceStore: AllowanceStore {
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let deviceID: String
    private let receipt: @Sendable () async -> String?
    /// See `SpareClient`. Omitted when nil; the proxy answers 404 either way.
    private let clientToken: String?

    public init(
        transport: any HTTPTransport,
        baseURL: URL,
        deviceID: String,
        receipt: @escaping @Sendable () async -> String? = { nil },
        clientToken: String? = nil
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.receipt = receipt
        self.clientToken = clientToken
    }

    public func startTrial() async -> TrialStartResult? {
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

    public func read() async -> AllowanceMirror? {
        guard let body = await post("/v1/allowance") else { return nil }
        return try? JSONDecoder().decode(AllowanceMirror.self, from: body)
    }

    /// A named object out of a response, as its own JSON document.
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
        // Sent so the server can tell a subscriber from a free device, and so
        // it can refuse to burn a subscriber's trial eligibility.
        if let receipt = await receipt(), !receipt.isEmpty {
            payload["receipt"] = .string(receipt)
        }

        var headers = [
            "content-type": "application/json",
            "x-spare-device": deviceID,
        ]
        if let clientToken, !clientToken.isEmpty {
            headers["x-spare-client"] = clientToken
        }

        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: headers,
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
/// day 4, the morning after expiry, or one lesson short of a monthly cap
/// without waiting or faking a clock.
public actor StubAllowanceStore: AllowanceStore {
    private var mirror: AllowanceMirror

    public init(_ mirror: AllowanceMirror = AllowanceMirror(trial: .eligible)) {
        self.mirror = mirror
    }

    // A second designated initialiser rather than a convenience one:
    // delegating inits on a reference type must be `convenience`, and
    // `convenience` is not available on an actor.
    public init(trial: TrialMirror, premium: PremiumAllowance? = nil) {
        self.mirror = AllowanceMirror(trial: trial, premium: premium)
    }

    public func startTrial() async -> TrialStartResult? {
        guard mirror.trial.status == .eligible else {
            return TrialStartResult(started: false, reason: "alreadyUsed", trial: mirror.trial)
        }
        let now = Date()
        mirror.trial = TrialMirror(
            status: .active,
            remainingLessons: TrialLimits.lessons,
            remainingCourses: TrialLimits.courses,
            startedAt: now,
            expiresAt: now.addingTimeInterval(TrialLimits.duration)
        )
        return TrialStartResult(started: true, trial: mirror.trial)
    }

    public func read() async -> AllowanceMirror? { mirror }
}

/// A proxy that cannot be reached.
///
/// Exists so the screenshot walkthrough can photograph what a device with no
/// network sees, which is the case that produced the worst bug in this
/// feature: an unreachable server used to read as "your free week is over",
/// and the day-7 summary fired for somebody who had never had one.
public struct UnreachableAllowanceStore: AllowanceStore {
    public init() {}
    public func startTrial() async -> TrialStartResult? { nil }
    public func read() async -> AllowanceMirror? { nil }
}
