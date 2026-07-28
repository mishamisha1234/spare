import Foundation
import SwiftData
import SpareCore

/// SwiftData wrapper around a `RecallQuestion` plus its schedule.
///
/// Generated at lesson completion and stored locally, so tomorrow's question is
/// instant and works with no network.
@Model
final class StoredRecallItem {
    var lessonID: UUID
    var question: String
    var answer: String
    var distractors: [String]
    var explanation: String
    var dueAt: Date
    /// Index into `RecallScheduler.intervalDays`.
    var intervalStage: Int
    var lastResultRaw: String
    /// Fixed per item so option order is stable across view reloads without
    /// being persisted as an array.
    var optionSeed: Int64

    init(
        lessonID: UUID,
        question: String,
        answer: String,
        distractors: [String],
        explanation: String,
        dueAt: Date,
        intervalStage: Int = 0,
        lastResult: RecallResult = .unseen,
        optionSeed: Int64 = Int64.random(in: 1...Int64.max)
    ) {
        self.lessonID = lessonID
        self.question = question
        self.answer = answer
        self.distractors = distractors
        self.explanation = explanation
        self.dueAt = dueAt
        self.intervalStage = intervalStage
        self.lastResultRaw = lastResult.rawValue
        self.optionSeed = optionSeed
    }

    convenience init(
        question: RecallQuestion,
        lessonID: UUID,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.init(
            lessonID: lessonID,
            question: question.question,
            answer: question.answer,
            distractors: question.distractors,
            explanation: question.explanation,
            dueAt: RecallScheduler.dueDate(forStage: 0, from: now, calendar: calendar),
            intervalStage: 0,
            lastResult: .unseen
        )
    }

    var lastResult: RecallResult {
        get { RecallResult(rawValue: lastResultRaw) ?? .unseen }
        set { lastResultRaw = newValue.rawValue }
    }

    var recallQuestion: RecallQuestion {
        RecallQuestion(
            question: question,
            answer: answer,
            distractors: distractors,
            explanation: explanation
        )
    }

    /// The four options in a stable order.
    var options: [String] {
        recallQuestion.options(seed: UInt64(bitPattern: optionSeed))
    }

    func isDue(at date: Date = .now) -> Bool { dueAt <= date }

    /// Records an answer and advances or regresses the schedule.
    func record(correct: Bool, now: Date = .now, calendar: Calendar = .current) {
        let next = RecallScheduler.reschedule(
            stage: intervalStage, correct: correct, now: now, calendar: calendar
        )
        intervalStage = next.stage
        dueAt = next.dueAt
        lastResult = correct ? .correct : .incorrect
    }
}
