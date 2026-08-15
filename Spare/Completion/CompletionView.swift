import SwiftUI
import SwiftData
import SpareCore

/// "Things I now know" gets one new entry. Offer: mark complete, go deeper,
/// or return home.
struct CompletionView: View {
    let lessonID: UUID
    let provider: LessonProvider
    let modelContext: ModelContext
    var onGoDeeper: (DeeperAngle) -> Void
    var onReturnHome: () -> Void
    var onTakeTest: () -> Void

    @StateObject private var viewModel: CompletionViewModel
    @State private var lesson: StoredLesson?
    @State private var isMarkedComplete = false
    @State private var isChoosingAngle = false
    @Query private var entitlements: [StoredEntitlement]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pointsLedger) private var pointsLedger
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    private var isPremium: Bool {
        (entitlements.first?.snapshot ?? .free).tier.isPremium
    }

    init(
        lessonID: UUID,
        provider: LessonProvider,
        modelContext: ModelContext,
        onGoDeeper: @escaping (DeeperAngle) -> Void,
        onReturnHome: @escaping () -> Void,
        onTakeTest: @escaping () -> Void
    ) {
        self.lessonID = lessonID
        self.provider = provider
        self.modelContext = modelContext
        self.onGoDeeper = onGoDeeper
        self.onReturnHome = onReturnHome
        self.onTakeTest = onTakeTest
        _viewModel = StateObject(wrappedValue: CompletionViewModel(provider: provider, modelContext: modelContext))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if let lesson {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Things I now know")
                            .font(Theme.Font.caption.font)
                            .foregroundStyle(palette.secondaryText)
                        Text(lesson.title)
                            .font(Theme.Font.title.font)
                            .foregroundStyle(palette.text)
                    }

                    VStack(spacing: Theme.Spacing.s) {
                        primaryButton(
                            title: isMarkedComplete ? "Marked complete" : "Mark complete",
                            isDisabled: isMarkedComplete
                        ) {
                            let alreadyCompleted = lesson.completedAt != nil
                            viewModel.markComplete(lesson)
                            isMarkedComplete = true
                            // Idempotent: re-tapping an already-complete
                            // lesson (or revisiting this screen) must not
                            // mint points twice for the same lesson.
                            if !alreadyCompleted {
                                awardCompletionPoints(for: lesson)
                            }
                        }
                        .accessibilityIdentifier("completion.markComplete")

                        secondaryButton(title: "Go deeper") {
                            isChoosingAngle.toggle()
                        }
                        .accessibilityIdentifier("completion.goDeeper")

                        if isPremium {
                            secondaryButton(title: "Take a 3-question test", action: onTakeTest)
                                .accessibilityIdentifier("completion.takeTest")
                        }

                        if isChoosingAngle {
                            VStack(spacing: Theme.Spacing.xs) {
                                ForEach(lesson.angles) { angle in
                                    Button {
                                        onGoDeeper(angle)
                                    } label: {
                                        Text(angle.text)
                                            .font(Theme.Font.label.font)
                                            .foregroundStyle(palette.text)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, Theme.Spacing.s)
                                            .frame(height: Theme.ControlSize.optionRow)
                                            .background(
                                                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                                    .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("completion.angle.\(angle.id)")
                                }
                            }
                        }

                        secondaryButton(title: "Return home", action: onReturnHome)
                            .accessibilityIdentifier("completion.returnHome")
                    }
                } else {
                    ProgressView().tint(palette.accent)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let stored = modelContext.storedLesson(id: lessonID)
            lesson = stored
            isMarkedComplete = stored?.completedAt != nil
            if let stored {
                await viewModel.ensureRecallGenerated(for: stored)
            }
        }
        // No container-level accessibilityIdentifier: SwiftUI can propagate
        // one down and clobber every descendant's own identifier — confirmed
        // for OnboardingView via an app.debugDescription dump in CI. Every
        // control on this screen already carries its own identifier.
    }

    private func awardCompletionPoints(for lesson: StoredLesson) {
        let ledger = pointsLedger
        let event = PointEvent(
            occurredAt: .now,
            kind: .lessonCompleted,
            amount: Points.forCompleting(lesson.window),
            sourceID: lesson.id.uuidString
        )
        Task { await ledger.record(event) }
    }

    private func primaryButton(title: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(palette.accent)
                        .opacity(isDisabled ? Theme.Interaction.disabledOpacity : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                )
        }
        .buttonStyle(.plain)
    }
}
