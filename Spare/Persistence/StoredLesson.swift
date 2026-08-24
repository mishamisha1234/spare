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
    /// The subject as it was *asked for*, and the interest category it was
    /// asked for under.
    ///
    /// Not the same as `title` and `topicTag`, which the model wrote. The pool
    /// keys entries on what the client sent, so anything that wants to find
    /// this lesson's attachments later has to ask with the same two strings —
    /// and a lesson called "The clock that beat the railways" filed under a
    /// request for "How standard time was imposed" would look up nothing,
    /// forever, silently.
    ///
    /// Empty for rows written before attachments existed, which read as "no
    /// attachments to look for" rather than as a wrong lookup.
    var requestedTopic: String = ""
    var requestedInterest: String = ""
    /// The post-lesson test, as generated with the lesson and stored beside it.
    ///
    /// JSON rather than a relationship, for the same reason
    /// `StoredSuggestionCache` holds Data: the value type stays owned by
    /// SpareCore. Nil where there is none — a free-pool lesson, or a premium
    /// one whose attachment upload has not landed yet.
    var testData: Data?

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
        isFavorite: Bool = false,
        requestedTopic: String = "",
        requestedInterest: String = ""
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
        self.requestedTopic = requestedTopic
        self.requestedInterest = requestedInterest
    }

    /// How the pool names this lesson. Nil when it was written before the
    /// requested subject was recorded, which is not a lookup worth making.
    var poolIdentity: LessonIdentity? {
        guard !requestedTopic.isEmpty else { return nil }
        return LessonIdentity(
            window: window, topic: requestedTopic, interest: requestedInterest
        )
    }

    var postLessonTest: [RecallQuestion] {
        get {
            guard let testData else { return [] }
            return (try? JSONDecoder().decode([RecallQuestion].self, from: testData)) ?? []
        }
        set {
            testData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }

    convenience init(
        lesson: Lesson,
        window: TimeWindow,
        id: UUID = UUID(),
        parentLessonID: UUID? = nil,
        generatedAt: Date = .now,
        requestedTopic: String = "",
        requestedInterest: String = ""
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
            parentLessonID: parentLessonID,
            requestedTopic: requestedTopic,
            requestedInterest: requestedInterest
        )
    }

    /// `TimeWindow.stored` rather than `init(rawValue:)`: it also understands
    /// the pre-30-minute `"fortyFive"` value, which would otherwise fall
    /// through to `.three` and turn an old course into a One Thing.
    var window: TimeWindow {
        get { TimeWindow.stored(rawValue: windowRaw) ?? .three }
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
