import Foundation

/// The reverse trial's instrumentation, and the whole of it.
///
/// No analytics SDK, per the standing constraint. What exists instead is a
/// local log of six event kinds, summarised on a DEBUG-only Settings screen,
/// plus two of those events forwarded to five global integers on the server.
///
/// The split is not arbitrary. §6's question is *"what percentage of users
/// dismiss the day-0 paywall and then complete 3 or more lessons during the
/// free week"* — and a percentage needs a denominator that spans devices. A
/// device-local log can only ever say what one device did, which is useful
/// for checking the wiring and useless for the decision. The server counters
/// answer the question; the local log is how you confirm the events are being
/// recorded at all.
public enum FunnelEvent: String, Codable, Sendable, CaseIterable {
    /// The day-0 paywall, raised by the first completed lesson.
    case paywallShown
    /// Closed without buying. Forwarded: the server cannot see it.
    case paywallDismissed
    case trialStarted
    /// A lesson finished while the trial was running.
    case trialLessonCompleted
    case trialEnded
    /// A purchase. Forwarded; the server decides whether it was the day-7
    /// decision or a later one, because that is the number the day-7 screen
    /// is judged by and a client should not be reporting on itself.
    case converted

    /// Whether the server needs to hear about this one.
    ///
    /// Three of the six it already knows: it starts the trials, it counts the
    /// lessons, and it knows when a week is up. Sending those again would be
    /// two sources for one number, and the client's would be the wrong one.
    public var isReportedToServer: Bool {
        switch self {
        case .paywallDismissed, .converted: true
        case .paywallShown, .trialStarted, .trialLessonCompleted, .trialEnded: false
        }
    }
}

/// What the local log adds up to. Pure, so it is tested on Linux.
public struct FunnelCounts: Sendable, Equatable {
    public var paywallsShown: Int
    public var paywallsDismissed: Int
    public var trialsStarted: Int
    public var trialLessonsCompleted: Int
    public var trialsEnded: Int
    public var conversions: Int

    public init(
        paywallsShown: Int = 0,
        paywallsDismissed: Int = 0,
        trialsStarted: Int = 0,
        trialLessonsCompleted: Int = 0,
        trialsEnded: Int = 0,
        conversions: Int = 0
    ) {
        self.paywallsShown = paywallsShown
        self.paywallsDismissed = paywallsDismissed
        self.trialsStarted = trialsStarted
        self.trialLessonsCompleted = trialLessonsCompleted
        self.trialsEnded = trialsEnded
        self.conversions = conversions
    }

    /// This device's answer to §6's question, for the one device it can speak
    /// for. `nil` when no paywall has been dismissed here — there is nothing
    /// to be a share *of*, and reporting 0% would be a claim rather than an
    /// absence.
    public var didEngageAfterDismissal: Bool? {
        guard paywallsDismissed > 0 else { return nil }
        return trialLessonsCompleted >= FunnelThresholds.engagedLessons
    }

    public static func summarise(_ events: [FunnelEvent]) -> FunnelCounts {
        var counts = FunnelCounts()
        for event in events {
            switch event {
            case .paywallShown: counts.paywallsShown += 1
            case .paywallDismissed: counts.paywallsDismissed += 1
            case .trialStarted: counts.trialsStarted += 1
            case .trialLessonCompleted: counts.trialLessonsCompleted += 1
            case .trialEnded: counts.trialsEnded += 1
            case .converted: counts.conversions += 1
            }
        }
        return counts
    }
}

/// Mirrors `FUNNEL_ENGAGED_LESSONS` in `server/src/limits.ts`.
public enum FunnelThresholds {
    /// Enough of the week read to have an opinion about it.
    public static let engagedLessons = 3
    /// Above this share, §6 says the model works and the lever is pricing.
    public static let healthyPercent = 40
    /// Under this, the problem is the lessons and no pricing change fixes it.
    public static let unhealthyPercent = 15
}

/// Forwards the two events the server cannot see.
public protocol FunnelReporter: Sendable {
    func report(_ event: FunnelEvent) async
}

/// Does nothing, for previews, tests, and any build with no proxy configured.
public struct NoopFunnelReporter: FunnelReporter {
    public init() {}
    public func report(_ event: FunnelEvent) async {}
}

/// One small POST, best-effort.
///
/// Failures are swallowed on purpose and never retried. A missed counter is a
/// slightly wrong marketing number; a retry queue for one would be more
/// machinery than the number is worth, and an error surfaced to the reader
/// would be an analytics call breaking an app that does not have analytics.
public struct ProxyFunnelReporter: FunnelReporter {
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let deviceID: String

    public init(transport: any HTTPTransport, baseURL: URL, deviceID: String) {
        self.transport = transport
        self.baseURL = baseURL
        self.deviceID = deviceID
    }

    public func report(_ event: FunnelEvent) async {
        guard event.isReportedToServer,
              let url = URL(string: "/v1/funnel", relativeTo: baseURL)
        else { return }

        let body = try? JSONEncoder().encode(
            JSONValue.object(["event": .string(event.rawValue)])
        )
        // The device identifier is sent because the router requires one on
        // every request, and because a conversion has to be resolved against
        // *this* device's trial. It is not stored against the counters: see
        // `FunnelLedger`, which holds five integers and nothing else.
        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: ["content-type": "application/json", "x-spare-device": deviceID],
            body: body,
            timeout: 10
        )
        _ = try? await transport.send(request)
    }
}
