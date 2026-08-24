import Foundation
import SwiftData
import SpareCore

/// Puts tomorrow's recall question and — for premium — the post-lesson test
/// onto the lesson, silently, on arrival. Also marks a lesson complete.
///
/// The order matters and is the whole design. A lesson's attachments belong to
/// the *lesson*, not the reader, so this asks the pool first and only generates
/// what is not already there. A 30-minute course read by two hundred premium
/// readers is written once and tested once; generating a test per reader would
/// be roughly $40 of tests on a $1.40 lesson.
@MainActor
final class CompletionViewModel: ObservableObject {
    /// True while the recall question and, for premium, the test are being
/// prepared. Covers both now, not just the recall question.
@Published private(set) var isPreparingAttachments = false

    private let provider: LessonProvider
    private let attachments: any AttachmentStore
    private let modelContext: ModelContext
    private let isPremium: Bool
    /// Held rather than awaited by the view.
    ///
    /// `.task` is tied to the view's lifetime, and the reader's very next
    /// action is to push the test screen on top of this one -- which is
    /// exactly when a view-bound task can be cancelled. The work would then
    /// stop half way, leaving the lesson with a recall question and no test,
    /// and the screen that reads it would honestly report that there is none.
    /// An unstructured task owned by the model outlives the push.
    private var preparation: Task<Void, Never>?

    init(
        provider: LessonProvider,
        attachments: any AttachmentStore,
        modelContext: ModelContext,
        isPremium: Bool
    ) {
        self.provider = provider
        self.attachments = attachments
        self.modelContext = modelContext
        self.isPremium = isPremium
    }

    func ensureAttachmentsReady(for lesson: StoredLesson) {
        guard preparation == nil else { return }
        preparation = Task { [weak self] in await self?.prepare(for: lesson) }
    }

    private func prepare(for lesson: StoredLesson) async {
        let lessonID = lesson.id
        let existing = FetchDescriptor<StoredRecallItem>(
            predicate: #Predicate { $0.lessonID == lessonID }
        )
        let hasRecall = (try? modelContext.fetch(existing).first) != nil
        // Premium wants both. Free-pool lessons have no test and never will,
        // so a missing one is not a reason to keep asking.
        let wantsTest = isPremium && lesson.postLessonTest.isEmpty
        guard !hasRecall || wantsTest else { return }

        isPreparingAttachments = true
        defer { isPreparingAttachments = false }

        let identity = lesson.poolIdentity

        // Already attached by whoever generated this lesson — most reads, once
        // a pool has filled. Nothing is generated and nothing is billed.
        if let identity, let stored = try? await attachments.attachments(for: identity) {
            apply(stored, to: lesson, hasRecall: hasRecall)
            return
        }

        // Nothing attached, so this device is the one that generated the
        // lesson and owes the pool its artifacts.
        //
        // Best-effort throughout: a missing recall question is not worth
        // blocking the completion screen over, and neither is a failed upload.
        guard let recall = try? await provider.generateRecallQuestion(for: lesson.lesson) else {
            return
        }
        var test: [RecallQuestion] = []
        if isPremium {
            test = (try? await provider.generatePostLessonTest(
                for: lesson.lesson, window: lesson.window
            )) ?? []
        }

        apply(LessonAttachments(recall: recall, test: test), to: lesson, hasRecall: hasRecall)

        // The upload is what makes this a once-per-lesson cost rather than a
        // once-per-reader one. If it fails the next reader regenerates, which
        // is the safe direction: a wasted call, not a wrong lesson.
        if let identity {
            try? await attachments.attach(
                LessonAttachments(recall: recall, test: test), for: identity
            )
        }
    }

    private func apply(_ stored: LessonAttachments, to lesson: StoredLesson, hasRecall: Bool) {
        if !hasRecall {
            modelContext.insert(StoredRecallItem(question: stored.recall, lessonID: lesson.id))
        }
        if !stored.test.isEmpty {
            lesson.postLessonTest = stored.test
        }
        try? modelContext.save()
        NotificationScheduler.reschedule(modelContext: modelContext)
    }

    func markComplete(_ lesson: StoredLesson) {
        lesson.completedAt = .now
        lesson.scrollProgress = 1
        try? modelContext.save()
    }
}
