import Foundation
import SpareCore

/// Where a Reader push came from: a fresh topic pick, or "go deeper" on an
/// already-read lesson. Carries only IDs and value types — never a SwiftData
/// model — so it stays `Hashable` for `NavigationPath`.
enum ReaderSource: Hashable {
    case newTopic(TopicSuggestion, window: TimeWindow)
    case goDeeper(parentLessonID: UUID, angle: DeeperAngle, window: TimeWindow)
}

/// Every pushable destination in the app.
enum AppRoute: Hashable {
    case suggestions(TimeWindow)
    case reader(ReaderSource)
    case completion(lessonID: UUID)
    case library
    /// Re-reading an already-generated lesson from the Library — a static
    /// render, not a new streaming session.
    case lessonDetail(UUID)
}
