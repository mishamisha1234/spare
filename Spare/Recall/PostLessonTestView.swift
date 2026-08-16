import SwiftUI
import SwiftData
import SpareCore

/// The immediate, optional 3-question test right after a lesson (premium).
/// One question at a time, immediate reveal, same quiet visual language as
/// the daily recall card — this is a bigger dose of the same mechanic, not a
/// different one.
struct PostLessonTestView: View {
    let lessonID: UUID
    let provider: LessonProvider
    let modelContext: ModelContext
    var onFinished: () -> Void

    @StateObject private var viewModel: PostLessonTestViewModel
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    init(
        lessonID: UUID,
        provider: LessonProvider,
        modelContext: ModelContext,
        pointsLedger: any PointsLedger,
        onFinished: @escaping () -> Void
    ) {
        self.lessonID = lessonID
        self.provider = provider
        self.modelContext = modelContext
        self.onFinished = onFinished
        _viewModel = StateObject(wrappedValue: PostLessonTestViewModel(
            lessonID: lessonID, provider: provider, pointsLedger: pointsLedger
        ))
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
                            guard let lesson = modelContext.storedLesson(id: lessonID)?.lesson else { return }
                            Task { await viewModel.start(lesson: lesson) }
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
            guard let lesson = modelContext.storedLesson(id: lessonID)?.lesson else { return }
            await viewModel.start(lesson: lesson)
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

            VStack(spacing: Theme.Spacing.xs) {
                ForEach(viewModel.currentOptions, id: \.self) { option in
                    optionRow(option, question: question)
                }
            }

            if viewModel.isRevealed {
                Text(question.explanation)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)

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

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("\(viewModel.correctCount) of \(viewModel.questions.count) correct")
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
                .accessibilityIdentifier("postLessonTest.summary")

            secondaryButton(title: "Done", action: onFinished)
                .accessibilityIdentifier("postLessonTest.done")
        }
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
