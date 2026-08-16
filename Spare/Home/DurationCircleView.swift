import SwiftUI
import SpareCore

/// One tappable circle on Home. Diameter is the only thing that communicates
/// duration — the course circle is additionally filled with the accent as
/// the visual anchor for the whole screen.
struct DurationCircleView: View {
    var window: TimeWindow
    /// Whether this *length* is behind Premium. Deliberately not "can't start
    /// a lesson right now": a free reader who has used today's lesson still
    /// owns the 3- and 10-minute lengths, and marking all four circles
    /// because of a daily limit would say something false about the plan.
    var isLocked: Bool = false
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var diameter: CGFloat { Theme.CircleSize.diameter(for: window) }
    private var isAnchor: Bool { window == .thirty }

    /// The dashed ring has to sit on whatever is behind it. On the
    /// accent-filled anchor that means the on-accent colour; everywhere else
    /// the usual hairline.
    private var lockedStrokeColor: Color {
        isAnchor
            ? palette.textOnAccent.opacity(Theme.Interaction.lockedContentOpacity)
            : palette.border
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Fill is untouched by locking: the anchor stays the anchor.
                Circle()
                    .fill(isAnchor ? palette.accent : Color.clear)

                if isLocked {
                    Circle()
                        .strokeBorder(
                            lockedStrokeColor,
                            style: StrokeStyle(lineWidth: Theme.borderWidth, dash: Theme.lockedDash)
                        )
                } else {
                    Circle()
                        .strokeBorder(isAnchor ? Color.clear : palette.border, lineWidth: Theme.borderWidth)
                }

                Text(window.label)
                    .font(Theme.Font.circleLabel(diameter: diameter))
                    .foregroundStyle(isAnchor ? palette.textOnAccent : palette.text)
                    .opacity(isLocked ? Theme.Interaction.lockedContentOpacity : 1)
                    .minimumScaleFactor(Theme.Interaction.circleLabelMinimumScale)
                    .lineLimit(1)
            }
            .frame(width: diameter, height: diameter)
            // Tap target never shrinks below the accessibility minimum, even
            // for the smallest (58pt) circle.
            .frame(
                minWidth: Theme.CircleSize.minimumTapTarget,
                minHeight: Theme.CircleSize.minimumTapTarget
            )
            .contentShape(Circle())
        }
        .buttonStyle(CircleButtonStyle())
        .accessibilityIdentifier("home.circle.\(window.rawValue)")
        // The dashed ring is a purely visual cue, so the lock has to be said
        // out loud for VoiceOver rather than left to the border style.
        .accessibilityLabel(
            isLocked
                ? "\(window.label), \(window.format.displayName), Premium"
                : "\(window.label), \(window.format.displayName)"
        )
    }
}

/// Presses dim rather than scale or recolor — no new token needed beyond
/// standard opacity.
private struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Theme.Interaction.pressedOpacity : 1)
    }
}

#Preview("Unlocked") {
    HStack(spacing: Theme.Spacing.m) {
        ForEach(TimeWindow.allCases) { window in
            DurationCircleView(window: window) {}
        }
    }
    .padding()
}

#Preview("Free tier: 15 and 45 locked") {
    HStack(spacing: Theme.Spacing.m) {
        ForEach(TimeWindow.allCases) { window in
            DurationCircleView(window: window, isLocked: !window.isFreeTierEligible) {}
        }
    }
    .padding()
}
