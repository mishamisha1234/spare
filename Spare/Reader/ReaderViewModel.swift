import Foundation
import SwiftData
import SpareCore

/// Drives one Reader session: starts the stream (or the one-shot "go deeper"
/// call), feeds events into a `RevisionGate`, and persists the canonical
/// lesson once revision finishes. The reader never sees pass-1 output — see
/// `RevisionGate` for why.
@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var blocks: [LessonBlock] = []
    @Published private(set) var isRevealed = false
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var isFinished = false
    @Published private(set) var persistedLessonID: UUID?
    @Published private(set) var scrollProgress: Double = 0
    @Published private(set) var failure: ErrorPresentation?

    let window: TimeWindow
    private let source: ReaderSource
    /// What was asked for, as opposed to what the model titled it. The pool
    /// keys on this, so the lesson has to remember it or its attachments can
    /// never be found again. See `StoredLesson.requestedTopic`.
    private let requested: (topic: String, interest: String)
    private let provider: LessonProvider
    private let modelContext: ModelContext
    private var gate: RevisionGate
    private var streamTask: Task<Void, Never>?

    /// Back-pressure on chaptered lessons: generation waits on this, so a
    /// reader who stops at chapter 2 is never billed for chapters 3-6.
    private let demand = ChapterDemand()
    private var lastSignalledChapter = -1

    init(source: ReaderSource, provider: LessonProvider, modelContext: ModelContext) {
        self.source = source
        self.provider = provider
        self.modelContext = modelContext
        switch source {
        case .newTopic(let topic, let window):
            self.window = window
            self.requested = (topic.title, topic.domainTag)
        case .goDeeper(_, let angle, let window):
            self.window = window
            // A go-deeper lesson's subject is the angle, which is what the
            // generation call sends as its topic.
            self.requested = (angle.text, "")
        }
        self.gate = RevisionGate(window: window)
    }

    // No deinit cancelling the task: `deinit` is nonisolated, so touching
    // isolated state from it is a Swift 6 error. `stop()` from `.onDisappear`
    // is the cancellation path.

    /// Minutes remaining, using the final word count once known and a stable
    /// upper-bound estimate while still streaming.
    var minutesRemaining: Int {
        let total = gate.finalLesson?.wordCount ?? window.wordBudget.upperBound
        let estimate = ReadingTime.minutesRemaining(totalWordCount: total, progress: scrollProgress)
        // Clamped to the duration the reader actually chose. Generated bodies
        // routinely land a little over the word budget, so the raw estimate
        // read "11 min left" on a lesson picked from the 10-minute circle —
        // the one number on the screen that has to agree with the button they
        // pressed.
        return min(estimate, window.minutes)
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops generation when the reader leaves. Without this, a backgrounded
    /// mini-course would keep drafting chapters nobody is going to read.
    func stop() {
        streamTask?.cancel()
        demand.finish()
    }

    /// Called as the reader scrolls, on a 0...1 fraction of the currently
    /// revealed content. Feeds `RevisionGate` so pacing stays honest, drives
    /// the nav-bar time estimate, and releases the next chapter.
    func updateScrollProgress(_ progress: Double) {
        scrollProgress = progress
        gate.updateReaderProgress(progress)

        let chapter = gate.readerChapterIndex
        if chapter > lastSignalledChapter {
            lastSignalledChapter = chapter
            demand.readerReached(chapter: chapter)
        }
    }

    private func run() async {
        switch source {
        case .newTopic(let topic, let window):
            await streamNewLesson(topic: topic, window: window)
        case .goDeeper(let parentLessonID, let angle, let window):
            await generateDeeperLesson(parentLessonID: parentLessonID, angle: angle, window: window)
        }
    }

    private func streamNewLesson(topic: TopicSuggestion, window: TimeWindow) async {
        let profile = modelContext.currentProfileSnapshot()
        do {
            for try await event in provider.streamLesson(
                topic: topic, window: window, profile: profile, demand: demand
            ) {
                gate.apply(event)
                syncFromGate()

                switch event {
                case .revisedChapterFinished:
                    // Persist progressively: a reader who stops at chapter 2
                    // should still find those two chapters in their library.
                    persistProgress(parentLessonID: nil)
                case .finished(let lesson):
                    persistCanonical(lesson, parentLessonID: nil)
                default:
                    break
                }
            }
        } catch let error as LessonProviderError {
            failure = ProviderErrorCopy.presentation(for: error)
        } catch {
            failure = ProviderErrorCopy.unexpected
        }
    }

    private func generateDeeperLesson(parentLessonID: UUID, angle: DeeperAngle, window: TimeWindow) async {
        guard let parent = modelContext.storedLesson(id: parentLessonID) else {
            failure = ErrorPresentation(
                title: "Lesson missing",
                message: "The lesson this was going deeper on is no longer in your library.",
                isRetryable: false
            )
            return
        }
        let profile = modelContext.currentProfileSnapshot()
        do {
            let lesson = try await provider.goDeeper(
                from: parent.lesson, angle: angle, window: window, profile: profile
            )
            // Both passes already ran inside `goDeeper`; there is no
            // incremental pipeline to reveal, so this arrives whole.
            gate.apply(.metadata(lesson.metadata))
            gate.apply(.revisedDelta(chapter: 0, text: lesson.bodyMarkdown))
            gate.apply(.finished(lesson))
            syncFromGate()
            persistCanonical(lesson, parentLessonID: parentLessonID)
        } catch let error as LessonProviderError {
            failure = ProviderErrorCopy.presentation(for: error)
        } catch {
            failure = ProviderErrorCopy.unexpected
        }
    }

    private func syncFromGate() {
        blocks = LessonBlockParser.parse(gate.displayText)
        isRevealed = gate.isRevealed
        holdProgress = gate.holdProgress
    }

    // MARK: - Persistence

    private func persistProgress(parentLessonID: UUID?) {
        guard let metadata = gate.metadata, !gate.displayText.isEmpty else { return }

        if let id = persistedLessonID, let existing = modelContext.storedLesson(id: id) {
            existing.bodyMarkdown = gate.displayText
        } else {
            let stored = StoredLesson(
                title: metadata.title,
                subtitle: metadata.subtitle,
                topicTag: metadata.domainTag,
                window: window,
                bodyMarkdown: gate.displayText,
                parentLessonID: parentLessonID,
                requestedTopic: requested.topic,
                requestedInterest: requested.interest
            )
            modelContext.insert(stored)
            persistedLessonID = stored.id
        }
        try? modelContext.save()
    }

    private func persistCanonical(_ lesson: Lesson, parentLessonID: UUID?) {
        if let id = persistedLessonID, let existing = modelContext.storedLesson(id: id) {
            existing.applyRevised(lesson)
        } else {
            let stored = StoredLesson(
                lesson: lesson, window: window, parentLessonID: parentLessonID,
                requestedTopic: requested.topic, requestedInterest: requested.interest
            )
            modelContext.insert(stored)
            persistedLessonID = stored.id
        }
        try? modelContext.save()
        isFinished = true
    }

    // The local `message(for:)` that used to live here is gone: it was one of
    // three separate places that each turned the same errors into their own
    // wording, which is how "rate limited" and "offline" ended up
    // indistinguishable on two of them. `ProviderErrorCopy` is now the single
    // source, and it carries retryability too, which a bare string could not.
}
