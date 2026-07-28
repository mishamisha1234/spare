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

    var window: TimeWindow {
        get { TimeWindow(rawValue: windowRaw) ?? .three }
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
