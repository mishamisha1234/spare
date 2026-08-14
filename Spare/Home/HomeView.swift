import SwiftUI
import SpareCore

/// The hero screen. One job: ask how long the reader has. Nothing else
/// competes for attention — no feed, no streak counter, no "continue reading"
/// carousel.
struct HomeView: View {
    var onSelect: (TimeWindow) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    /// Two rows, each pairing a smaller and larger circle rather than a rigid
    /// size-ordered grid — the pairing itself is the "not a grid" cue.
    private static let topRow: [TimeWindow] = [.three, .ten]
    private static let bottomRow: [TimeWindow] = [.fifteen, .fortyFive]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Spacing.s)

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

            VStack(spacing: Theme.Spacing.m) {
                row(Self.topRow)
                row(Self.bottomRow)
            }

            // Uncapped: absorbs the rest of the screen below the group so the
            // group sits in the optical center of the space under the title,
            // rather than the exact geometric center two equal spacers give.
            Spacer(minLength: Theme.Spacing.l)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .themedAppear()
        // No container-level accessibilityIdentifier: see OnboardingView for
        // why (confirmed to clobber descendant identifiers). Nothing needs
        // this one — home.circle.* and home.libraryButton are what's tested.
    }

    private func row(_ windows: [TimeWindow]) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            ForEach(windows) { window in
                DurationCircleView(window: window) { onSelect(window) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

#Preview {
    HomeView(onSelect: { _ in })
}

#Preview("Dark") {
    HomeView(onSelect: { _ in })
        .preferredColorScheme(.dark)
}
