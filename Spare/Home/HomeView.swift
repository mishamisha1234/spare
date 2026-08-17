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

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    /// Two rows, each pairing a smaller and larger circle rather than a rigid
    /// size-ordered grid — the pairing itself is the "not a grid" cue.
    private static let topRow: [TimeWindow] = [.three, .ten]
    private static let bottomRow: [TimeWindow] = [.fifteen, .thirty]

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

    private var content: some View {
        VStack(spacing: 0) {
            // The title + grid block is optically centred in the space under
            // the toolbar, then lifted. Two equal Spacers would centre it
            // geometrically, which sits too low once the eye accounts for the
            // toolbar above it.
            Spacer(minLength: Theme.Spacing.m)

            Text("How long do you have?")
                .font(Theme.Font.largeTitle.font)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // 32pt, down from 40: the title and the thing it is asking about
            // were reading as two separate blocks.
            Spacer(minLength: Theme.Spacing.m)
                .frame(maxHeight: Theme.Spacing.ml)

            durationGrid

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
                ForEach(TimeWindow.allCases) { window in
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
                ForEach(TimeWindow.allCases) { window in
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
