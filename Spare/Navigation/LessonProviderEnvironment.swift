import SwiftUI
import SpareCore

/// Injects the active `LessonProvider` down the view hierarchy. Phase 2 wires
/// `MockProvider` at the root; swapping to `AnthropicDirectProvider` in
/// Phase 3 is a one-line change here.
private struct LessonProviderKey: EnvironmentKey {
    // A computed property, not `static let`: EnvironmentKey.defaultValue has
    // an unconstrained associated Value type, so a stored static let reads as
    // process-wide shared mutable state under Swift 6 strict concurrency,
    // even though MockProvider itself is Sendable. Computing a fresh value
    // per access sidesteps the diagnostic — SpareApp always overrides this
    // via `.environment(\.lessonProvider, MockProvider())` anyway, so the
    // default is only ever read by previews and tests.
    static var defaultValue: LessonProvider { MockProvider() }
}

extension EnvironmentValues {
    var lessonProvider: LessonProvider {
        get { self[LessonProviderKey.self] }
        set { self[LessonProviderKey.self] = newValue }
    }
}
