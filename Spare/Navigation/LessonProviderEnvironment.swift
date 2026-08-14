import SwiftUI
import SpareCore

/// Injects the active `LessonProvider` down the view hierarchy. Phase 2 wires
/// `MockProvider` at the root; swapping to `AnthropicDirectProvider` in
/// Phase 3 is a one-line change here.
private struct LessonProviderKey: EnvironmentKey {
    static let defaultValue: LessonProvider = MockProvider()
}

extension EnvironmentValues {
    var lessonProvider: LessonProvider {
        get { self[LessonProviderKey.self] }
        set { self[LessonProviderKey.self] = newValue }
    }
}
