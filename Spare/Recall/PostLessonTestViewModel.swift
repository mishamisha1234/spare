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
    @Published private(set) var errorMessage: String?
    @Published private(set) var isFinished = false

    private let lessonID: UUID
    private let provider: LessonProvider
    private let pointsLedger: any PointsLedger
    /// One stable option order per question, fixed at load time so the
    /// order doesn't reshuffle mid-question on a view refresh.
    private var optionSeeds: [UInt64] = []

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
        guard questions.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            questions = try await provider.generatePostLessonTest(for: lesson)
            optionSeeds = questions.map { _ in UInt64.random(in: 1...UInt64.max) }
            if questions.isEmpty {
                errorMessage = "Couldn't generate a test for this lesson. Please try again later."
            }
        } catch {
            errorMessage = "Couldn't generate a test for this lesson. Please try again later."
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
