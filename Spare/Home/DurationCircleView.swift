import SwiftUI
import SpareCore

/// One tappable circle on Home.
///
/// Diameter carries the duration. The accent fill is reserved for a course
/// actually in progress — it used to sit permanently on the 30-minute
/// circle, which meant that for a free reader the loudest element on Home
/// was a locked upsell wearing the primary-action colour.
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
    private var isResuming: Bool { resumeChapterIndex != nil }

    /// Accent fill means "there is something here to come back to", not
    /// "this is the longest option".
    private var isFilled: Bool { isResuming }

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

    /// The dashed ring has to sit on whatever is behind it. On the
    /// accent-filled anchor that means the on-accent colour; everywhere else
    /// the usual hairline.
    private var contentColor: Color {
        isFilled ? palette.textOnAccent : palette.text
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(isFilled ? palette.accent : Color.clear)
                    // One stroke treatment for every state. Locked circles
                    // used a dash, which read as a second kind of control
                    // rather than as the same control unavailable.
                    Circle()
                        .strokeBorder(
                            isFilled ? Color.clear : palette.borderInteractive,
                            lineWidth: Theme.borderWidth
                        )

                    VStack(spacing: Theme.Spacing.xxs) {
                        Text(title)
                            .font(Theme.Font.circleLabel)
                            .foregroundStyle(contentColor)
                            .minimumScaleFactor(Theme.Interaction.circleLabelMinimumScale)
                            .lineLimit(2)

                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.Font.caption.font)
                                .foregroundStyle(isFilled ? palette.textOnAccent : palette.secondaryText)
                                .minimumScaleFactor(Theme.Interaction.circleLabelMinimumScale)
                                .lineLimit(1)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xs)
                }
                .frame(width: diameter, height: diameter)

                // The lock sits under the circle rather than inside it, so
                // it never competes with the label for the circle's area and
                // the state is legible before the tap.
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(Theme.Font.caption.font)
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityHidden(true)
                }
            }
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
