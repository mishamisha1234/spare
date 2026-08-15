import SwiftUI
import SpareCore

/// Injects the active `PointsLedger` down the view hierarchy, the same way
/// `LessonProviderEnvironment` injects the provider.
private struct PointsLedgerKey: EnvironmentKey {
    // Computed, not `static let`, for the same reason as `LessonProviderKey`:
    // `EnvironmentKey.defaultValue`'s unconstrained associated type makes a
    // stored static read as process-wide shared mutable state under Swift 6
    // strict concurrency. SpareApp always overrides this via
    // `.environment(\.pointsLedger, ...)`; the default is only ever read by
    // previews and tests.
    static var defaultValue: any PointsLedger { NoopPointsLedger() }
}

extension EnvironmentValues {
    var pointsLedger: any PointsLedger {
        get { self[PointsLedgerKey.self] }
        set { self[PointsLedgerKey.self] = newValue }
    }
}
