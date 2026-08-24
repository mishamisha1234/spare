import SwiftUI
import SwiftData
import SpareCore

/// The immediate, optional test right after a lesson (premium). Two questions
/// at a minute, ten after a course. One question at a time, immediate reveal,
/// same quiet visual language as the daily recall card — this is a bigger dose
/// of the same mechanic, not a different one.
///
/// Holds no provider, deliberately. The test is already on the lesson or it is
/// not; a screen with a provider on it is a screen that can grow a "generate
/// one" path, and that path is the $40-of-tests-on-a-$1.40-lesson cliff.
struct PostLessonTestView: View {
    let lessonID: UUID
    let modelContext: ModelContext
    var onFinished: () -> Void

    @StateObject private var viewModel: PostLessonTestViewModel
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    init(
        lessonID: UUID,
        modelContext: ModelContext,
        pointsLedger: any PointsLedger,
        onFinished: @escaping () -> Void
    ) {
        self.lessonID = lessonID
        self.modelContext = modelContext
        self.onFinished = onFinished
        _viewModel = StateObject(wrappedValue: PostLessonTestViewModel(
            lessonID: lessonID, pointsLedger: pointsLedger
        ))
    }

    /// Four seconds, in quarter-second steps. Long enough to cover two model
    /// calls finishing on the screen behind this one, short enough that a
    /// lesson which genuinely has no test says so rather than hanging.
    private static let attachmentPollAttempts = 16
    private static let attachmentPollInterval: UInt64 = 250_000_000

    /// The test as it was attached to the lesson. Nothing here generates one:
    /// see `PostLessonTestViewModel`.
    private var storedQuestions: [RecallQuestion] {
        modelContext.storedLesson(id: lessonID)?.postLessonTest ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if viewModel.isLoading {
                    ProgressView().tint(palette.accent)
                } else if let failure = viewModel.failure {
                    ErrorStateView(
                        presentation: failure,
                        onRetry: {
                            viewModel.start(stored: storedQuestions)
                        },
                        identifier: "postLessonTest.error"
                    )
                } else if viewModel.isFinished {
                    summary
                } else if let question = viewModel.currentQuestion {
                    questionBody(question)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .navigationTitle("Quick test")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Waits for the attachment before deciding there is none.
            //
            // The test is written and stored moments after the lesson
            // finishes, on the completion screen this reader just came from,
            // and a fast reader arrives first. "No test for this one" is a
            // real state -- a free-pool lesson, or an upload that never landed
            // -- but it is not this one, and showing it here would be telling
            // the reader something untrue about a lesson that is about to have
            // a test. Bounded, and it generates nothing either way.
            for _ in 0..<Self.attachmentPollAttempts {
                let questions = storedQuestions
                if !questions.isEmpty {
                    viewModel.start(stored: questions)
                    return
                }
                try? await Task.sleep(nanoseconds: Self.attachmentPollInterval)
            }
            viewModel.start(stored: storedQuestions)
        }
        // No container-level accessibilityIdentifier: see OnboardingView.
    }

    private func questionBody(_ question: RecallQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Question \(viewModel.currentIndex + 1) of \(viewModel.questions.count)")
                .font(Theme.Font.eyebrow.font)
                .tracking(Theme.Font.eyebrow.tracking)
                .foregroundStyle(palette.secondaryText)

            Text(question.question)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)

            // 12pt against ~100pt-tall cards; 8pt read as cramped and 16pt
            // pushed the fourth option off the fold.
            VStack(spacing: Theme.Spacing.optionRowGap) {
                ForEach(viewModel.currentOptions, id: \.self) { option in
                    optionRow(option, question: question)
                }
            }

            if viewModel.isRevealed {
                // Trimmed: the fixture prefixed this with "The central claim
                // of the piece: " and then repeated the chosen option, so the
                // reader read the same sentence twice.
                if !question.trimmedExplanation.isEmpty {
                    Text(question.trimmedExplanation)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                secondaryButton(
                    title: viewModel.currentIndex + 1 < viewModel.questions.count ? "Next" : "See results",
                    action: viewModel.advance
                )
                .accessibilityIdentifier("postLessonTest.next")
            }
        }
    }

    private func optionRow(_ option: String, question: RecallQuestion) -> some View {
        let isCorrectOption = option == question.answer
        return Button {
            viewModel.select(option)
        } label: {
            HStack {
                Text(option)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(rowTextColor(isCorrectOption: isCorrectOption))
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.s)
            .frame(minHeight: Theme.ControlSize.optionRow)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(rowBorderColor(isCorrectOption: isCorrectOption), lineWidth: Theme.borderWidth)
            )
            // See RecallCardView's identical fix: a stroke only draws pixels
            // along the border, so without this the row's interior isn't
            // hit-testable at all.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRevealed)
        .accessibilityIdentifier("postLessonTest.option.\(option)")
    }

    private func rowBorderColor(isCorrectOption: Bool) -> Color {
        guard viewModel.isRevealed else { return palette.borderInteractive }
        return isCorrectOption ? palette.accent : palette.borderInteractive
    }

    private func rowTextColor(isCorrectOption: Bool) -> Color {
        guard viewModel.isRevealed else { return palette.text }
        return isCorrectOption ? palette.text : palette.secondaryText
    }

    /// The score, then every question with what they chose.
    ///
    /// A bare "1 of 3 correct" plus a Done button used about a tenth of the
    /// screen and gave the reader no way to see which two they missed —
    /// which is the only part of a recall test worth reading.
    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("\(viewModel.correctCount) of \(viewModel.questions.count) correct")
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
                .accessibilityIdentifier("postLessonTest.summary")

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(viewModel.questions, id: \.question) { question in
                    resultRow(question)
                }
            }

            primaryButton(title: "Done", action: onFinished)
                .accessibilityIdentifier("postLessonTest.done")
        }
    }

    private func resultRow(_ question: RecallQuestion) -> some View {
        let chosen = viewModel.answers[question.question]
        let wasCorrect = chosen == question.answer
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(question.question)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(wasCorrect ? "Correct" : "You chose: \(chosen ?? "nothing")")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Accent-filled: on the result screen this is the only action.
    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(palette.accent)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
                )
        }
        .buttonStyle(.plain)
    }
}
