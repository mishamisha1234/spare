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
    @Published private(set) var errorMessage: String?

    let window: TimeWindow
    private let source: ReaderSource
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
        case .newTopic(_, let window), .goDeeper(_, _, let window):
            self.window = window
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
        return ReadingTime.minutesRemaining(totalWordCount: total, progress: scrollProgress)
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
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "The lesson stopped generating. Please go back and try again."
        }
    }

    private func generateDeeperLesson(parentLessonID: UUID, angle: DeeperAngle, window: TimeWindow) async {
        guard let parent = modelContext.storedLesson(id: parentLessonID) else {
            errorMessage = "Couldn't find the lesson this was going deeper on."
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
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "Couldn't generate that lesson. Please go back and try again."
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
                parentLessonID: parentLessonID
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
                lesson: lesson, window: window, parentLessonID: parentLessonID
            )
            modelContext.insert(stored)
            persistedLessonID = stored.id
        }
        try? modelContext.save()
        isFinished = true
    }

    private static func message(for error: LessonProviderError) -> String {
        switch error {
        case .missingAPIKey:
            return "Add an API key in Settings to generate live lessons."
        case .refused:
            return "The model declined to write about this topic. Try another one."
        case .cancelled:
            return "Generation stopped."
        case .httpStatus(let code, _) where code == 429:
            return "Rate limited. Give it a minute and try again."
        default:
            return "The lesson stopped generating. Please go back and try again."
        }
    }
}
