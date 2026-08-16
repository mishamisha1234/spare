import Foundation
import SpareCore

/// Drives the immediate, optional post-lesson test: generates 3 questions,
/// steps through them one at a time with immediate reveal, and records a
/// `PointEvent` per answer. Never persisted as a schedule — unlike the daily
/// recall card, there is nothing here for `RecallScheduler` to track.
@MainActor
final class PostLessonTestViewModel: ObservableObject {
    @Published private(set) var questions: [RecallQuestion] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var selectedOption: String?
    @Published private(set) var isRevealed = false
    @Published private(set) var correctCount = 0
    @Published private(set) var isLoading = true
    @Published private(set) var failure: ErrorPresentation?
    @Published private(set) var isFinished = false

    private let lessonID: UUID
    private let provider: LessonProvider
    private let pointsLedger: any PointsLedger
    /// One stable option order per question, fixed at load time so the
    /// order doesn't reshuffle mid-question on a view refresh.
    private var optionSeeds: [UInt64] = []
    /// Which lesson the loaded questions actually belong to.
    ///
    /// `questions.isEmpty` alone was the guard, which caches by "have I
    /// loaded anything" rather than "have I loaded *this*". If SwiftUI reuses
    /// this view model across a different lessonID, that serves the previous
    /// lesson's questions under the new lesson's title — silently, and
    /// looking entirely normal.
    private var loadedLessonID: UUID?

    init(lessonID: UUID, provider: LessonProvider, pointsLedger: any PointsLedger) {
        self.lessonID = lessonID
        self.provider = provider
        self.pointsLedger = pointsLedger
    }

    var currentQuestion: RecallQuestion? {
        questions.indices.contains(currentIndex) ? questions[currentIndex] : nil
    }

    var currentOptions: [String] {
        guard let question = currentQuestion, optionSeeds.indices.contains(currentIndex) else { return [] }
        return question.options(seed: optionSeeds[currentIndex])
    }

    func start(lesson: Lesson) async {
        // Keyed to the lesson, not merely to "something is loaded".
        guard loadedLessonID != lessonID || questions.isEmpty else { return }
        if loadedLessonID != lessonID {
            questions = []
            optionSeeds = []
            currentIndex = 0
            selectedOption = nil
            isRevealed = false
            correctCount = 0
            isFinished = false
        }
        isLoading = true
        // Cleared up front so a retry doesn't show the previous failure
        // underneath the new attempt.
        failure = nil
        defer { isLoading = false }
        do {
            questions = try await provider.generatePostLessonTest(for: lesson)
            loadedLessonID = lessonID
            // Seeded from the question text, not randomly: a random seed
            // reshuffles the options on every view refresh of the same
            // question, which is the recall-card bug in another place.
            optionSeeds = questions.map { RecallQuestion.stableSeed(for: $0.question) }
            if questions.isEmpty {
                // Succeeded but returned nothing. Not an error condition —
                // there is no thrown error to describe — so it gets its own
                // honest wording rather than being dressed up as a failure.
                failure = ErrorPresentation(
                    title: "No questions",
                    message: "The model didn't produce a test for this lesson. Trying again usually works.",
                    isRetryable: true
                )
            }
        } catch {
            failure = (error as? LessonProviderError).map(ProviderErrorCopy.presentation) ?? ProviderErrorCopy.unexpected
        }
    }

    func select(_ option: String) {
        guard !isRevealed, let question = currentQuestion else { return }
        selectedOption = option
        isRevealed = true
        let correct = option == question.answer
        if correct { correctCount += 1 }

        let ledger = pointsLedger
        let event = PointEvent(
            occurredAt: .now,
            kind: correct ? .postLessonTestCorrect : .postLessonTestIncorrect,
            amount: correct ? Points.forCorrectRecall : Points.forIncorrectRecall,
            sourceID: lessonID.uuidString
        )
        Task { await ledger.record(event) }
    }

    func advance() {
        guard currentIndex + 1 < questions.count else {
            isFinished = true
            return
        }
        currentIndex += 1
        selectedOption = nil
        isRevealed = false
    }
}
