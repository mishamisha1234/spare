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

    /// Called as the reader scrolls, on a 0...1 fraction of the currently
    /// revealed content. Feeds `RevisionGate` so pacing stays honest, and
    /// drives the nav-bar time estimate.
    func updateScrollProgress(_ progress: Double) {
        scrollProgress = progress
        gate.updateReaderProgress(progress)
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
            for try await event in provider.streamLesson(topic: topic, window: window, profile: profile) {
                gate.apply(event)
                syncFromGate()
                if case .finished(let lesson) = event {
                    persist(lesson: lesson, parentLessonID: nil)
                }
            }
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
            // No incremental pipeline is exposed for "go deeper" — reveal the
            // whole thing at once rather than fake a stream.
            gate.apply(.revisedDelta(chapter: 0, text: lesson.bodyMarkdown))
            gate.apply(.finished(lesson))
            syncFromGate()
            persist(lesson: lesson, parentLessonID: parentLessonID)
        } catch {
            errorMessage = "Couldn't generate that lesson. Please go back and try again."
        }
    }

    private func syncFromGate() {
        blocks = LessonBlockParser.parse(gate.displayText)
        isRevealed = gate.isRevealed
        holdProgress = gate.holdProgress
    }

    private func persist(lesson: Lesson, parentLessonID: UUID?) {
        let stored = StoredLesson(lesson: lesson, window: window, parentLessonID: parentLessonID)
        modelContext.insert(stored)
        try? modelContext.save()
        persistedLessonID = stored.id
        isFinished = true
    }
}
