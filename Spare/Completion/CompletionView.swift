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
    var onPaywall: (PaywallTrigger) -> Void

    @StateObject private var viewModel: CompletionViewModel
    @State private var lesson: StoredLesson?
    @State private var isMarkedComplete = false
    @State private var isChoosingAngle = false

    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pointsLedger) private var pointsLedger
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    init(
        lessonID: UUID,
        provider: LessonProvider,
        modelContext: ModelContext,
        attachments: any AttachmentStore,
        isPremium: Bool,
        onGoDeeper: @escaping (DeeperAngle) -> Void,
        onReturnHome: @escaping () -> Void,
        onTakeTest: @escaping () -> Void,
        onPaywall: @escaping (PaywallTrigger) -> Void
    ) {
        self.lessonID = lessonID
        self.provider = provider
        self.modelContext = modelContext
        self.onGoDeeper = onGoDeeper
        self.onReturnHome = onReturnHome
        self.onTakeTest = onTakeTest
        self.onPaywall = onPaywall
        // Both passed in rather than read from the environment: `StateObject`
        // is built in `init`, where environment values are not available yet.
        _viewModel = StateObject(wrappedValue: CompletionViewModel(
            provider: provider,
            attachments: attachments,
            modelContext: modelContext,
            isPremium: isPremium
        ))
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

                        if isMarkedComplete {
                            Text("Saved to your library")
                                .font(Theme.Font.label.font)
                                .foregroundStyle(palette.secondaryText)
                                .accessibilityIdentifier("completion.saved")
                        }
                    }

                    VStack(spacing: Theme.Spacing.s) {
                        // Once complete, the button goes entirely rather than
                        // sitting there disabled. A dead grey box was the
                        // heaviest element on the screen and nothing on it
                        // was the primary action.
                        if !isMarkedComplete {
                            primaryButton(title: "Mark complete", isDisabled: false) {
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
                        }

                        // Both premium actions stay visible when locked, with
                        // the lock shown rather than the row hidden: a
                        // feature nobody can see sells nothing, and silently
                        // missing rows are worse UX than an honest lock.
                        lockableButton(
                            title: "Go deeper",
                            decision: entitlements.canGoDeeper(),
                            identifier: "completion.goDeeper"
                        ) {
                            isChoosingAngle.toggle()
                        }

                        lockableButton(
                            title: "Take a \(lesson.window.testQuestionCount)-question test",
                            decision: entitlements.canTakePostLessonTest(),
                            identifier: "completion.takeTest",
                            action: onTakeTest
                        )

                        if isMarkedComplete {
                            primaryButton(title: "Return home", isDisabled: false, action: onReturnHome)
                                .accessibilityIdentifier("completion.returnHome")
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
                                            .frame(minHeight: Theme.ControlSize.optionRow)
                                            .background(
                                                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                                    .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
                                            )
                                            // A stroke only draws pixels along the border, so
                                            // without this the row's interior — everything past
                                            // the label glyphs — isn't hit-testable at all,
                                            // exactly where XCUITest's tap-at-frame-center lands
                                            // on a short, left-aligned label.
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("completion.angle.\(angle.id)")
                                }
                            }
                        }

                        // Secondary only while the lesson is unfinished; once
                        // marked complete it is promoted to the accent-filled
                        // primary above.
                        if !isMarkedComplete {
                            secondaryButton(title: "Return home", action: onReturnHome)
                                .accessibilityIdentifier("completion.returnHome")
                        }
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
                viewModel.ensureAttachmentsReady(for: stored)
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

    /// A secondary button that either performs its action or, when the gate
    /// says no, routes to the paywall carrying the specific trigger.
    ///
    /// Note it reads the whole `AccessDecision`, not a bool: a `.capped`
    /// decision (a paying user at the mini-course limit) shows the lock
    /// without offering to sell them anything, because `.trigger` is nil.
    private func lockableButton(
        title: String,
        decision: AccessDecision,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let isLocked = !decision.isAllowed
        return Button {
            if let trigger = decision.trigger {
                onPaywall(trigger)
            } else if !isLocked {
                action()
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                // Full text colour even when locked: at secondary these read
                // as broken rather than gated, and two of four rows were
                // near-invisible.
                Text(title)
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(Theme.Font.caption.font)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.ControlSize.button)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(isLocked ? "\(title), Premium" : title)
    }

    private func primaryButton(title: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Border-only when disabled, matching the Save key button in
            // Settings. A dimmed accent fill turns muddy in dark mode, where
            // the accent already sits close to the background in luminance —
            // "Marked complete" was rendering as brown-on-brown.
            Text(title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(isDisabled ? palette.secondaryText : palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(isDisabled ? Color.clear : palette.accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(
                            isDisabled ? palette.borderInteractive : Color.clear,
                            lineWidth: Theme.borderWidth
                        )
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
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
                )
        }
        .buttonStyle(.plain)
    }
}
