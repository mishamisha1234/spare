import Foundation
import SwiftData
import SpareCore

/// One cached suggestion set per time window, so the Suggestions screen renders
/// instantly and refreshes in the background.
@Model
final class StoredSuggestionCache {
    @Attribute(.unique) var windowRaw: String
    /// JSON-encoded `[TopicSuggestion]`. Stored as data rather than as a
    /// transformable array so the value type stays owned by SpareCore.
    var suggestionsData: Data
    var generatedAt: Date

    init(window: TimeWindow, suggestions: [TopicSuggestion], generatedAt: Date = .now) {
        self.windowRaw = window.rawValue
        self.suggestionsData = (try? JSONEncoder().encode(suggestions)) ?? Data()
        self.generatedAt = generatedAt
    }

    /// `TimeWindow.stored` rather than `init(rawValue:)`, for the same reason
    /// `StoredLesson` uses it.
    ///
    /// This was the plain initialiser with a `?? .three` behind it, which is
    /// the exact shape of the bug the shared decoder exists to prevent: a row
    /// written under a raw value the app no longer has decodes to nil, falls
    /// to the default, and a cached set of 7-minute suggestions starts
    /// answering the 3-minute circle. Nothing crashes and nothing logs.
    ///
    /// Legacy rows are also deleted outright at launch — see
    /// `PersistenceStack.normalizeLegacyWindows` — so in practice this decodes
    /// a value only in the window between an upgrade and the first launch after
    /// it. That is exactly the window in which a wrong default would be wrong.
    var window: TimeWindow {
        get { TimeWindow.stored(rawValue: windowRaw) ?? .three }
        set { windowRaw = newValue.rawValue }
    }

    var suggestions: [TopicSuggestion] {
        get { (try? JSONDecoder().decode([TopicSuggestion].self, from: suggestionsData)) ?? [] }
        set { suggestionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Cache is shown immediately regardless of age; this drives the background
    /// refresh, not the display.
    func isStale(now: Date = .now, maxAge: TimeInterval = 6 * 3_600) -> Bool {
        now.timeIntervalSince(generatedAt) > maxAge
    }
}
