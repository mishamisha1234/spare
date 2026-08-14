import Foundation

/// Exponential backoff for retryable API failures.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval

    public init(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 20
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    public static let standard = RetryPolicy()
    /// One attempt, no retries — used by tests that assert a failure surfaces.
    public static let single = RetryPolicy(maxAttempts: 1)

    /// Delay before the given (1-based) attempt. Attempt 1 never waits.
    ///
    /// Deliberately jitter-free: this is one device retrying its own request,
    /// not a fleet stampeding a service, and determinism makes it testable.
    public func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let raw = initialDelay * pow(multiplier, Double(attempt - 2))
        return min(raw, maxDelay)
    }
}

/// Indirection over `Task.sleep` so retry tests run instantly instead of
/// actually waiting out a backoff schedule.
public protocol Sleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Records what it was asked to wait for, without waiting.
///
/// An actor rather than a lock-guarded class: `sleep` is async, and NSLock's
/// `lock()`/`unlock()` are unavailable from async contexts (holding a lock
/// across a suspension point can deadlock).
public actor RecordingSleeper: Sleeper {
    public private(set) var recordedDelays: [TimeInterval] = []

    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        recordedDelays.append(seconds)
    }
}
