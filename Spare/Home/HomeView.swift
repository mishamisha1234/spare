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
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: Theme.Spacing.l)

            Text("How long do you have?")
                .font(Theme.Font.largeTitle.font)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: Theme.Spacing.l) {
                row(Self.topRow)
                row(Self.bottomRow)
            }

            Spacer(minLength: Theme.Spacing.l)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .themedAppear()
        .accessibilityIdentifier("home.screen")
    }

    private func row(_ windows: [TimeWindow]) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            ForEach(windows) { window in
                DurationCircleView(window: window) { onSelect(window) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    HomeView(onSelect: { _ in })
}

#Preview("Dark") {
    HomeView(onSelect: { _ in })
        .preferredColorScheme(.dark)
}
