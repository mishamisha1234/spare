import Foundation
import SwiftData
import SpareCore

/// SwiftData wrapper around a generated `Lesson`.
///
/// `bodyMarkdown` always holds the **revised** text: the reader never sees
/// unrevised prose, so unrevised prose is never persisted either.
@Model
final class StoredLesson {
    @Attribute(.unique) var id: UUID
    var title: String
    var subtitle: String
    var topicTag: String
    var windowRaw: String
    var bodyMarkdown: String
    var surprisingClaim: String
    var deeperAngles: [String]
    var generatedAt: Date
    var completedAt: Date?
    var scrollProgress: Double
    /// Set when this lesson came from "go deeper" on another lesson.
    var parentLessonID: UUID?
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        topicTag: String,
        window: TimeWindow,
        bodyMarkdown: String,
        surprisingClaim: String = "",
        deeperAngles: [String] = [],
        generatedAt: Date = .now,
        completedAt: Date? = nil,
        scrollProgress: Double = 0,
        parentLessonID: UUID? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.topicTag = topicTag
        self.windowRaw = window.rawValue
        self.bodyMarkdown = bodyMarkdown
        self.surprisingClaim = surprisingClaim
        self.deeperAngles = deeperAngles
        self.generatedAt = generatedAt
        self.completedAt = completedAt
        self.scrollProgress = scrollProgress
        self.parentLessonID = parentLessonID
        self.isFavorite = isFavorite
    }

    convenience init(
        lesson: Lesson,
        window: TimeWindow,
        id: UUID = UUID(),
        parentLessonID: UUID? = nil,
        generatedAt: Date = .now
    ) {
        self.init(
            id: id,
            title: lesson.title,
            subtitle: lesson.subtitle,
            topicTag: lesson.domainTag,
            window: window,
            bodyMarkdown: lesson.bodyMarkdown,
            surprisingClaim: lesson.surprisingClaim,
            deeperAngles: lesson.deeperAngles,
            generatedAt: generatedAt,
            parentLessonID: parentLessonID
        )
    }

    var window: TimeWindow {
        get { TimeWindow(rawValue: windowRaw) ?? .three }
        set { windowRaw = newValue.rawValue }
    }

    /// Value copy of the generated content.
    var lesson: Lesson {
        Lesson(
            title: title,
            subtitle: subtitle,
            domainTag: topicTag,
            bodyMarkdown: bodyMarkdown,
            surprisingClaim: surprisingClaim,
            deeperAngles: deeperAngles
        )
    }

    /// Minimal form used to exclude repeats from future suggestions.
    var digest: LessonDigest {
        LessonDigest(title: title, topicTag: topicTag, completedAt: completedAt)
    }

    var angles: [DeeperAngle] {
        deeperAngles.map(DeeperAngle.init(text:))
    }

    var wordCount: Int { bodyMarkdown.lessonWordCount }

    var minutesRemaining: Int {
        ReadingTime.minutesRemaining(totalWordCount: wordCount, progress: scrollProgress)
    }

    /// Persist the canonical revised body once the revision pass completes.
    func applyRevised(_ lesson: Lesson) {
        title = lesson.title
        subtitle = lesson.subtitle
        topicTag = lesson.domainTag
        bodyMarkdown = lesson.bodyMarkdown
        surprisingClaim = lesson.surprisingClaim
        deeperAngles = lesson.deeperAngles
    }
}
