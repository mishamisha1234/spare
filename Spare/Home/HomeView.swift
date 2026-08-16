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

    @Query private var recallItems: [StoredRecallItem]
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.colorScheme) private var colorScheme

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
            // Capped like the title-to-circles gap below: an uncapped Spacer
            // here grows in lockstep with the uncapped one at the bottom —
            // SwiftUI splits leftover space evenly between Spacers of equal
            // priority — which silently cancels out the "pull the group up"
            // intent. Confirmed by measuring the previous screenshot: top and
            // bottom empty space came out equal instead of bottom-heavy.
            Spacer(minLength: Theme.Spacing.s)
                .frame(maxHeight: Theme.Spacing.m)

            Text("How long do you have?")
                .font(Theme.Font.largeTitle.font)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Capped, not a bare Spacer: keeps the title close to the circles
            // on every screen height instead of stretching to split the
            // available space evenly, which is what read as a lot of dead air.
            Spacer(minLength: Theme.Spacing.m)
                .frame(maxHeight: Theme.Spacing.l)

            if let item = visibleRecallItem {
                RecallCardView(
                    item: item,
                    onViewLesson: onViewRecallLesson,
                    onDismiss: { isRecallDismissed = true }
                )
                .padding(.bottom, Theme.Spacing.m)
            }

            VStack(spacing: Theme.Spacing.m) {
                row(Self.topRow)
                row(Self.bottomRow)
            }

            // Uncapped: absorbs the rest of the screen below the group so the
            // group sits in the optical center of the space under the title,
            // rather than the exact geometric center two equal spacers give.
            // Inside the ScrollView this still works exactly as before when
            // content fits its minHeight floor; it only stops mattering once
            // content genuinely needs to scroll, which is the point.
            Spacer(minLength: Theme.Spacing.l)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity)
    }

    private var visibleRecallItem: StoredRecallItem? {
        isRecallDismissed ? nil : pinnedRecallItem
    }

    private func row(_ windows: [TimeWindow]) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(windows) { window in
                DurationCircleView(
                    window: window,
                    isLocked: entitlements.isWindowLocked(window)
                ) {
                    onSelect(window)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview("Free tier") {
    let container = PersistenceStack.makeContainer(inMemory: true)
    return HomeView(onSelect: { _ in }, onViewRecallLesson: { _ in })
        .modelContainer(container)
        .entitlementService(EntitlementService(store: StubPurchaseStore(), container: container))
}

#Preview("Free tier, dark") {
    let container = PersistenceStack.makeContainer(inMemory: true)
    return HomeView(onSelect: { _ in }, onViewRecallLesson: { _ in })
        .modelContainer(container)
        .entitlementService(EntitlementService(store: StubPurchaseStore(), container: container))
        .preferredColorScheme(.dark)
}
