import Foundation
import SwiftData
import SpareCore

/// Small read helpers shared by every view model that needs a value-type
/// snapshot of persisted state to hand to a `LessonProvider`.
extension ModelContext {
    func currentProfileSnapshot() -> ProfileSnapshot {
        let profiles = (try? fetch(FetchDescriptor<StoredProfile>())) ?? []
        return profiles.first?.snapshot ?? .empty
    }

    func recentLessonDigests(limit: Int = SuggestionValidator.historyWindow) -> [LessonDigest] {
        let descriptor = FetchDescriptor<StoredLesson>(
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        let lessons = (try? fetch(descriptor)) ?? []
        return lessons.prefix(limit).map(\.digest)
    }

    func storedLesson(id: UUID) -> StoredLesson? {
        let descriptor = FetchDescriptor<StoredLesson>(predicate: #Predicate { $0.id == id })
        return try? fetch(descriptor).first
    }

    // MARK: - Recall

    /// The recall item due soonest, whether or not it's due yet — used by
    /// `NotificationScheduler` to schedule ahead. Views decide what to show
    /// *today* from their own `@Query`, which stays observation-tracked;
    /// this one-off fetch is for a non-view context that has no `@Query`.
    func nextRecallItem() -> StoredRecallItem? {
        let items = (try? fetch(FetchDescriptor<StoredRecallItem>())) ?? []
        return items.min { $0.dueAt < $1.dueAt }
    }
}
