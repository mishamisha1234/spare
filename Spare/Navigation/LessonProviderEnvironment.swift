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

/// Where a lesson's recall question and test are read from and written to.
///
/// Separate from the provider on purpose: this one never calls a model, and
/// keeping the two apart is what makes "reading a test cannot cost money" a
/// property of the type rather than a rule to remember. The default attaches
/// nothing, which is right for previews, tests, and the offline mock — none of
/// which have a shared pool to attach to.
private struct AttachmentStoreKey: EnvironmentKey {
    static var defaultValue: AttachmentStore { NoAttachmentStore() }
}

extension EnvironmentValues {
    var lessonProvider: LessonProvider {
        get { self[LessonProviderKey.self] }
        set { self[LessonProviderKey.self] = newValue }
    }

    var attachmentStore: AttachmentStore {
        get { self[AttachmentStoreKey.self] }
        set { self[AttachmentStoreKey.self] = newValue }
    }
}
