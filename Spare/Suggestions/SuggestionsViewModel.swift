import Foundation
import SwiftData
import SpareCore

/// Loads suggestions for one window. Shows the cache instantly, if there is
/// one, and refreshes in the background — the reader should never watch a
/// loading state before they've had a chance to pick something.
@MainActor
final class SuggestionsViewModel: ObservableObject {
    @Published private(set) var suggestions: [TopicSuggestion] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    let window: TimeWindow
    private let provider: LessonProvider
    private let modelContext: ModelContext

    init(window: TimeWindow, provider: LessonProvider, modelContext: ModelContext) {
        self.window = window
        self.provider = provider
        self.modelContext = modelContext
    }

    func loadCacheThenRefresh() async {
        if let cached = try? modelContext.fetch(
            FetchDescriptor<StoredSuggestionCache>(
                predicate: #Predicate { $0.windowRaw == window.rawValue }
            )
        ).first {
            suggestions = cached.suggestions
        }
        await refresh(shuffled: false)
    }

    func shuffle() async {
        await refresh(shuffled: true)
    }

    private func refresh(shuffled: Bool) async {
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let history = modelContext.recentLessonDigests()
            let profile = modelContext.currentProfileSnapshot()
            var fresh = try await provider.suggestTopics(window: window, profile: profile, history: history)

            if !SuggestionValidator.isAcceptable(fresh, history: history, profile: profile) {
                fresh = SuggestionValidator.repairing(fresh)
            }
            if shuffled {
                // MockProvider is deterministic; reordering gives the control
                // visible feedback until AnthropicDirectProvider (Phase 3)
                // returns genuinely different suggestions per call.
                fresh.shuffle()
            }

            suggestions = fresh
            persistCache(fresh)
        } catch {
            if suggestions.isEmpty {
                errorMessage = "Couldn't load suggestions."
            }
        }
    }

    private func persistCache(_ suggestions: [TopicSuggestion]) {
        let descriptor = FetchDescriptor<StoredSuggestionCache>(
            predicate: #Predicate { $0.windowRaw == window.rawValue }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.suggestions = suggestions
            existing.generatedAt = .now
        } else {
            modelContext.insert(StoredSuggestionCache(window: window, suggestions: suggestions))
        }
        try? modelContext.save()
    }
}
