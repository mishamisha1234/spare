import SwiftUI
import SwiftData
import SpareCore

/// The hero screen. One job: ask how long the reader has. Nothing else
/// competes for attention — no feed, no streak counter, no "continue reading"
/// carousel. The one exception is the recall card, which is not
/// re-engagement chrome but the retention mechanic itself, and only appears
/// when a question is actually due.
struct HomeView: View {
    var onSelect: (TimeWindow) -> Void
    var onViewRecallLesson: (UUID) -> Void
    /// Resuming a part-read course: the lesson to reopen and the chapter to
    /// land on.
    var onResumeCourse: (UUID, Int) -> Void

    @Query private var recallItems: [StoredRecallItem]
    @Query(sort: \StoredLesson.generatedAt, order: .reverse)
    private var lessons: [StoredLesson]
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Pinned once per session the first time Home appears, then held
    /// through answering and dismissal regardless of how `dueAt` changes
    /// underneath — "one question per session maximum" means one recall
    /// opportunity per launch, not a card that reappears every time Home is
    /// revisited after a push/pop.
    @State private var pinnedRecallItem: StoredRecallItem?
    @State private var isRecallDismissed = false
    @AppStorage(.hasDismissedTrialNudge) private var hasDismissedTrialNudge = false

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    /// The four windows the 2x2 grid holds.
    ///
    /// Stated rather than taken from `TimeWindow.allCases`, which now has five
    /// entries: the 1-minute length is a different kind of thing and does not
    /// belong in the size progression. Iterating `allCases` here would silently
    /// turn the 2x2 into a 2x3 the moment a window was added, which is exactly
    /// what adding the 1-minute window would have done.
    private static let gridWindows: [TimeWindow] = [.three, .seven, .fifteen, .thirty]

    var body: some View {
        // GeometryReader + a `minHeight` on the content is the standard way
        // to get both things at once: the existing Spacer-based centering
        // when content fits (the common case, no card or a short one), and
        // real scrolling instead of an overlap when it doesn't. Confirmed
        // necessary via CI screenshot: the recall card's header + question +
        // four option rows + explanation + link is tall enough on its own
        // (~450-500pt) that no amount of text line-limiting keeps the full
        // circle grid on screen underneath it without this.
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height)
            }
        }
        .background(palette.background)
        .themedAppear()
        .onAppear {
            // Two guards, both necessary. A recall card is a question about
            // something you read; showing one to somebody who has finished
            // nothing is incoherent, and on a fresh install it appeared with
            // an already-answered question for a lesson they had never
            // opened. `nextDueItem` alone doesn't catch that, because seeded
            // or orphaned rows are still "due".
            guard hasFinishedSomething else { return }
            if pinnedRecallItem == nil {
                pinnedRecallItem = RecallScheduler.nextDueItem(from: recallItems, now: .now) { $0.dueAt }
            }
        }
        // No container-level accessibilityIdentifier: see OnboardingView for
        // why (confirmed to clobber descendant identifiers). Nothing needs
        // this one — home.circle.*, home.libraryButton, and recall.* are
        // what's tested.
    }

    /// The one line Home is allowed to carry that is not the question.
    ///
    /// Only ever one at a time, and only ever near a limit. A remaining count
    /// is a *disclosure* and cannot be dismissed -- an undisclosed cap is the
    /// App Review problem this project already fixed once. The day-4 trial
    /// line is a *report* and can be dismissed for good. Where both would
    /// apply the count wins, because it is the one that changes what the
    /// reader should do next.
    ///
    /// A subscriber's threshold is lower than a trialist's on purpose: a
    /// trialist sees their line for at most a week, where a subscriber would
    /// see one every month forever.
    private var allowanceLine: (text: String, isDismissible: Bool)? {
        if entitlements.isTrialing {
            let lessons = entitlements.trialLessonsRemaining
            if lessons < TrialCopy.lessonsRemainingBelow {
                return (TrialCopy.lessonsRemaining(lessons), false)
            }

            let days = entitlements.trialDaysRemaining()
            guard days <= TrialCopy.nudgeFromDaysRemaining, !hasDismissedTrialNudge else {
                return nil
            }
            return (TrialCopy.nudge(daysRemaining: days, thingsLearned: completedCount), true)
        }

        // Only from a real answer. No count at all beats a stale one, and the
        // server refuses regardless of what this line says.
        guard let premium = entitlements.allowance.premium,
              premium.lessonsRemaining <= PremiumCopy.lessonsRemainingBelow
        else { return nil }
        return (PremiumCopy.lessonsRemaining(premium.lessonsRemaining), false)
    }

    private var completedCount: Int {
        lessons.filter { $0.completedAt != nil }.count
    }

    @ViewBuilder
    private func allowanceLineView(_ line: (text: String, isDismissible: Bool)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text(line.text)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("home.allowanceLine")

            if line.isDismissible {
                Button {
                    hasDismissedTrialNudge = true
                } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Font.caption.font)
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.allowanceLine.dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // The title + grid block is optically centred in the space under
            // the toolbar, then lifted. Two equal Spacers would centre it
            // geometrically, which sits too low once the eye accounts for the
            // toolbar above it.
            Spacer(minLength: Theme.Spacing.m)

            // The one line Home is allowed to carry that is not the question.
            //
            // It sits above the title rather than below the grid because it
            // is a status report about something the reader was given, and
            // below the grid it would be under the recall card and read as
            // marketing. It is one line, it has no button, and the nudge half
            // of it can be dismissed for good.
            if let line = allowanceLine {
                allowanceLineView(line)
                    .layoutPriority(Theme.homeContentPriority)
                Spacer(minLength: Theme.Spacing.s)
                    .frame(maxHeight: Theme.Spacing.m)
            }

            Text("How long do you have?")
                .font(Theme.Font.largeTitle.font)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .layoutPriority(Theme.homeContentPriority)

            // 32pt, down from 40: the title and the thing it is asking about
            // were reading as two separate blocks.
            Spacer(minLength: Theme.Spacing.m)
                .frame(maxHeight: Theme.Spacing.ml)

            // The 1-minute circle, above the grid and not in it.
            //
            // It is a different kind of thing, not a fifth size: the grid is a
            // size progression carrying duration, and a fifth entry would read
            // as the bottom of that scale. Small, separate, and above -- which
            // is also where the eye lands first, and it is the length a free
            // reader cannot have.
            circle(.one)
                .layoutPriority(Theme.homeContentPriority)

            Spacer(minLength: Theme.Spacing.m)
                .frame(maxHeight: Theme.Spacing.ml)

            durationGrid
                .layoutPriority(Theme.homeContentPriority)

            // The recall card sits *below* the circles now.
            //
            // Above them it pushed the 15-minute and course circles off the
            // bottom of the screen — the app's primary action was not visible
            // at launch whenever a question was due. Home scrolls to
            // accommodate it, which the single-purpose constraint permits:
            // that rules out a tab bar and competing content, not a
            // ScrollView.
            if let item = visibleRecallItem {
                RecallCardView(
                    item: item,
                    onViewLesson: onViewRecallLesson,
                    onDismiss: { isRecallDismissed = true }
                )
                .padding(.top, Theme.Spacing.l)
                .layoutPriority(Theme.homeContentPriority)
            }

            // Weighted heavier than the top spacer, which is what produces
            // the upward offset rather than a hardcoded negative padding
            // that would fight the ScrollView.
            Spacer(minLength: Theme.Spacing.l)
                .layoutPriority(Theme.homeBottomSpacerPriority)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity)
    }

    /// 2x2 on a fixed two-column grid, or one centred column at accessibility
    /// sizes where two circles plus a gutter no longer fit.
    @ViewBuilder
    private var durationGrid: some View {
        if dynamicTypeSize >= .accessibility3 {
            VStack(spacing: Theme.Spacing.m) {
                ForEach(Self.gridWindows) { window in
                    circle(window)
                }
            }
        } else {
            // Fixed columns rather than edge-and-gutter: with circles of four
            // different diameters, laying them out by spacing put the row-1
            // and row-2 centres in different places, which is what made the
            // composition read as accidental.
            let columns = [
                GridItem(.flexible(), spacing: Theme.Spacing.m),
                GridItem(.flexible(), spacing: Theme.Spacing.m),
            ]
            LazyVGrid(columns: columns, spacing: Theme.Spacing.m) {
                ForEach(Self.gridWindows) { window in
                    circle(window)
                }
            }
        }
    }

    private func circle(_ window: TimeWindow) -> some View {
        let resumeIndex = resumeChapter(for: window)
        return DurationCircleView(
            window: window,
            isLocked: entitlements.isWindowLocked(window),
            resumeChapterIndex: resumeIndex
        ) {
            if let resumeIndex, let course = resumableCourse {
                onResumeCourse(course.id, resumeIndex)
            } else {
                onSelect(window)
            }
        }
    }

    /// True once at least one lesson has actually been completed.
    private var hasFinishedSomething: Bool {
        lessons.contains { $0.completedAt != nil }
    }

    private var visibleRecallItem: StoredRecallItem? {
        guard !isRecallDismissed, hasFinishedSomething else { return nil }
        return pinnedRecallItem
    }

    /// The most recent course the reader started and hasn't finished. Only
    /// one can be offered — the circle has room for a position, not a list.
    private var resumableCourse: StoredLesson? {
        lessons.first {
            CourseProgress.isResumable(
                window: $0.window,
                scrollProgress: $0.scrollProgress,
                completedAt: $0.completedAt
            )
        }
    }

    /// Not offered while the window is locked. A lapsed subscriber with a
    /// half-read course would otherwise see a dashed lock and an invitation
    /// to "Continue" on the same circle, which contradict each other. The
    /// lock is the honest thing to show — they can't start a new course —
    /// and the existing one is still readable from the Library.
    private func resumeChapter(for window: TimeWindow) -> Int? {
        guard
            window.format.isChaptered,
            !entitlements.isWindowLocked(window),
            let course = resumableCourse
        else { return nil }
        return CourseProgress.chapterIndex(
            scrollProgress: course.scrollProgress,
            chapterCount: window.format.chapterCount
        )
    }

}

#Preview("Free tier") {
    let container = PersistenceStack.makeContainer(inMemory: true)
    return HomeView(onSelect: { _ in }, onViewRecallLesson: { _ in }, onResumeCourse: { _, _ in })
        .modelContainer(container)
        .entitlementService(EntitlementService(store: StubPurchaseStore(), container: container))
}

#Preview("Free tier, dark") {
    let container = PersistenceStack.makeContainer(inMemory: true)
    return HomeView(onSelect: { _ in }, onViewRecallLesson: { _ in }, onResumeCourse: { _, _ in })
        .modelContainer(container)
        .entitlementService(EntitlementService(store: StubPurchaseStore(), container: container))
        .preferredColorScheme(.dark)
}
