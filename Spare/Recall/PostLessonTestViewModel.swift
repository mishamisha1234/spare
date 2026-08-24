import Foundation
import SpareCore

/// Drives the immediate, optional post-lesson test: steps through the stored
/// questions one at a time with immediate reveal, and records a `PointEvent`
/// per answer. Never persisted as a schedule — unlike the daily recall card,
/// there is nothing here for `RecallScheduler` to track.
///
/// **Generates nothing.** The test was written once, with the lesson, by the
/// device that generated it, and stored beside it in the pool; by the time a
/// reader taps through to here it is either on the lesson or it is not. That
/// is the whole cost argument: a cached 30-minute course read by two hundred
/// premium users must not trigger two hundred test generations, which would be
/// roughly $40 of tests on a $1.40 lesson. There is deliberately no fallback
/// path from "no test" to "make one" — a fallback is exactly how a cost cliff
/// gets reintroduced by someone fixing an empty screen.
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
    /// What the reader picked for each question, so the result screen can
    /// show which ones they missed rather than only a score.
    @Published private(set) var answers: [String: String] = [:]

    private let lessonID: UUID
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

    init(lessonID: UUID, pointsLedger: any PointsLedger) {
        self.lessonID = lessonID
        self.pointsLedger = pointsLedger
    }

    var currentQuestion: RecallQuestion? {
        questions.indices.contains(currentIndex) ? questions[currentIndex] : nil
    }

    var currentOptions: [String] {
        guard let question = currentQuestion, optionSeeds.indices.contains(currentIndex) else { return [] }
        return question.options(seed: optionSeeds[currentIndex])
    }

    /// - Parameter stored: the questions already on the lesson. Passed in
    ///   rather than fetched, so this type has no way to reach a provider and
    ///   therefore no way to grow a generation path later.
    func start(stored: [RecallQuestion]) {
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
            answers = [:]
        }
        // Nothing to wait for: the questions are already on the lesson.
        isLoading = false
        failure = nil
        questions = stored
        loadedLessonID = lessonID
        // Seeded from the question text, not randomly: a random seed
        // reshuffles the options on every view refresh of the same
        // question, which is the recall-card bug in another place.
        optionSeeds = questions.map { RecallQuestion.stableSeed(for: $0.question) }
        if questions.isEmpty {
            // No error to describe: nothing failed, there is simply no test on
            // this lesson. Not retryable, because retrying calls nothing —
            // the honest thing is to say so rather than offer a button that
            // re-runs the same read.
            failure = ErrorPresentation(
                title: "No test for this one",
                message: "This lesson was saved without a test. Try another lesson.",
                isRetryable: false
            )
        }
    }

    func select(_ option: String) {
        if let question = currentQuestion {
            answers[question.question] = option
        }
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
