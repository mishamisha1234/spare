import SwiftUI
import SpareCore

/// One tappable circle on Home. Diameter is the only thing that communicates
/// duration — the 45-minute circle is additionally filled with the accent as
/// the visual anchor for the whole screen.
struct DurationCircleView: View {
    var window: TimeWindow
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var diameter: CGFloat { Theme.CircleSize.diameter(for: window) }
    private var isAnchor: Bool { window == .fortyFive }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isAnchor ? palette.accent : Color.clear)
                Circle()
                    .strokeBorder(isAnchor ? Color.clear : palette.border, lineWidth: Theme.borderWidth)
                Text(window.label)
                    .font(Theme.Font.circleLabel(diameter: diameter))
                    .foregroundStyle(isAnchor ? palette.textOnAccent : palette.text)
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
        .accessibilityLabel("\(window.label), \(window.format.displayName)")
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

#Preview {
    HStack(spacing: Theme.Spacing.m) {
        ForEach(TimeWindow.allCases) { window in
            DurationCircleView(window: window) {}
        }
    }
    .padding()
}
