import Foundation
import SwiftData
import SpareCore

/// What the widget needs to render, read once per timeline refresh.
///
/// A value type rather than live `@Model` objects: the widget's rendering is
/// a snapshot by nature, and keeping SwiftData objects out of the view means
/// a schema change can't crash the extension in the background where nobody
/// sees the error.
struct WidgetSnapshot: Equatable {
    var thingsKnown: Int
    var resumableCourse: ResumableCourse?
    /// False when the App Group entitlement isn't in effect, which is
    /// different from "no lessons yet" and must not be rendered as a zero.
    var isStorageReachable: Bool

    struct ResumableCourse: Equatable {
        var lessonID: UUID
        var chapterIndex: Int
        var chapterCount: Int

        var positionLabel: String {
            CourseProgress.positionLabel(chapterIndex: chapterIndex, chapterCount: chapterCount)
        }
    }

    static let unavailable = WidgetSnapshot(
        thingsKnown: 0, resumableCourse: nil, isStorageReachable: false
    )

    /// Shown in the widget gallery, before the real store is read.
    static let placeholder = WidgetSnapshot(
        thingsKnown: 12, resumableCourse: nil, isStorageReachable: true
    )
}

/// Reads the shared store. Everything here is best-effort: a widget that
/// throws is a widget that shows an error card on someone's home screen, so
/// every failure degrades to "nothing to show" instead.
enum WidgetSnapshotReader {

    static func read() -> WidgetSnapshot {
        guard AppGroup.isSharedStorageAvailable else { return .unavailable }

        guard let container = try? ModelContainer(
            for: PersistenceStack.makeSchema(),
            configurations: ModelConfiguration(url: PersistenceStack.storeURL())
        ) else {
            return .unavailable
        }

        let context = ModelContext(container)
        let lessons = (try? context.fetch(
            FetchDescriptor<StoredLesson>(sortBy: [SortDescriptor(\.generatedAt, order: .reverse)])
        )) ?? []

        let completed = lessons.filter { $0.completedAt != nil }.count

        let course = lessons.first {
            CourseProgress.isResumable(
                window: $0.window,
                scrollProgress: $0.scrollProgress,
                completedAt: $0.completedAt
            )
        }

        return WidgetSnapshot(
            thingsKnown: completed,
            resumableCourse: course.map {
                WidgetSnapshot.ResumableCourse(
                    lessonID: $0.id,
                    chapterIndex: CourseProgress.chapterIndex(
                        scrollProgress: $0.scrollProgress,
                        chapterCount: $0.window.format.chapterCount
                    ),
                    chapterCount: $0.window.format.chapterCount
                )
            },
            isStorageReachable: true
        )
    }

    /// Which lengths are locked, read from the cached entitlement. The widget
    /// can't ask StoreKit — extensions get no reliable network time — so it
    /// uses the tier the app last persisted, and a stale answer costs at most
    /// one wrong-looking tap that the app then resolves correctly.
    static func lockedWindows() -> Set<TimeWindow> {
        guard AppGroup.isSharedStorageAvailable,
              let container = try? ModelContainer(
                for: PersistenceStack.makeSchema(),
                configurations: ModelConfiguration(url: PersistenceStack.storeURL())
              )
        else { return [] }

        let context = ModelContext(container)
        let snapshot = (try? context.fetch(FetchDescriptor<StoredEntitlement>()))?.first?.snapshot ?? .free
        let available = Set(EntitlementRules.availableWindows(snapshot))
        return Set(TimeWindow.allCases).subtracting(available)
    }
}
