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
    /// Zero-based chapter a part-read course is waiting at. Non-nil turns the
    /// circle into a resume affordance: the label becomes the position rather
    /// than the offer, because the reader is being invited back into
    /// something they started, not asked to pick a length.
    var resumeChapterIndex: Int?
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var diameter: CGFloat { Theme.CircleSize.diameter(for: window) }
    private var isAnchor: Bool { window == .thirty }

    private var isResuming: Bool { resumeChapterIndex != nil }

    /// Courses get a second line ("30 min · 4 chapters"), or the resume
    /// position once one is underway. The single-sitting windows have
    /// nothing to add below their own duration.
    private var title: String {
        guard let index = resumeChapterIndex else { return window.circleTitle }
        return CourseProgress.positionLabel(
            chapterIndex: index,
            chapterCount: window.format.chapterCount
        )
    }

    private var subtitle: String? {
        isResuming ? "Continue" : window.circleSubtitle
    }

    /// The two-line course label needs to be smaller than a bare "3 min", or
    /// it collides with the circle's edge. Derived from the same diameter
    /// scale so it still tracks size rather than inventing a constant.
    private var titleFont: SwiftUI.Font {
        subtitle == nil
            ? Theme.Font.circleLabel(diameter: diameter)
            : Theme.Font.circleLabel(diameter: diameter * Theme.CircleSize.stackedLabelScale)
    }

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

                VStack(spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(isAnchor ? palette.textOnAccent : palette.text)
                        .minimumScaleFactor(Theme.Interaction.circleLabelMinimumScale)
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Font.caption.font)
                            .foregroundStyle(isAnchor ? palette.textOnAccent : palette.secondaryText)
                            .minimumScaleFactor(Theme.Interaction.circleLabelMinimumScale)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xs)
                .opacity(isLocked ? Theme.Interaction.lockedContentOpacity : 1)
            }
            .frame(width: diameter, height: diameter)
            // Tap target never shrinks below the accessibility minimum, even
            // for the smallest circle.
            .frame(
                minWidth: Theme.CircleSize.minimumTapTarget,
                minHeight: Theme.CircleSize.minimumTapTarget
            )
            .contentShape(Circle())
        }
        .buttonStyle(CircleButtonStyle())
        .accessibilityIdentifier("home.circle.\(window.rawValue)")
        // The dashed ring and the stacked label are both purely visual, so
        // the lock and the resume position have to be said out loud rather
        // than left to a border style and a font size.
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let index = resumeChapterIndex {
            let position = CourseProgress.positionLabel(
                chapterIndex: index,
                chapterCount: window.format.chapterCount
            )
            return "Course, \(position), continue"
        }
        var text = "\(window.circleTitle), \(window.format.displayName)"
        if let subtitle = window.circleSubtitle {
            text = "\(window.circleTitle), \(subtitle)"
        }
        if isLocked {
            text += ", Premium"
        }
        return text
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
