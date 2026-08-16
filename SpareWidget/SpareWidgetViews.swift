import SwiftUI
import WidgetKit
import SpareCore

/// The widget's own palette.
///
/// `Theme` lives in the app target and pulls in app-only types, so rather
/// than dragging that across the target boundary the widget restates the
/// handful of values it needs — from the same hex literals, so the two stay
/// in step. A widget that doesn't match the app it belongs to is worse than
/// no widget.
enum WidgetPalette {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x111110) : Color(hex: 0xFAF8F5)
    }
    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xE8E6E1) : Color(hex: 0x1A1A1A)
    }
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x8F8A80) : Color(hex: 0x8A837A)
    }
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x3A3833) : Color(hex: 0xD8D2C8)
    }
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xD9924A) : Color(hex: 0xC87F2E)
    }
    static func textOnAccent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x17150F) : Color(hex: 0xFAF8F5)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Duration picker

/// Small and lock-screen: the same question Home asks, answerable without
/// opening the app first.
struct DurationWidgetView: View {
    var snapshot: WidgetSnapshot
    var lockedWindows: Set<TimeWindow>
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    /// A course in progress replaces the question entirely. Someone mid-course
    /// doesn't need to be asked how long they have — they already answered.
    private var resumable: WidgetSnapshot.ResumableCourse? { snapshot.resumableCourse }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            lockScreenBody
        default:
            homeScreenBody
        }
    }

    // MARK: Lock screen

    /// No background, no colour: the accessory family renders monochrome and
    /// is vibrancy-tinted by the system, so anything else is ignored at best.
    private var lockScreenBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let resumable {
                Text(resumable.positionLabel)
                    .font(.headline)
                Text("Continue")
                    .font(.caption)
            } else {
                Text("How long do you have?")
                    .font(.caption)
                HStack(spacing: 6) {
                    ForEach(unlockedWindows, id: \.self) { window in
                        Text(window.shortLabel)
                            .font(.headline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(resumable.map(resumeLink) ?? link(for: unlockedWindows.first ?? .three))
    }

    // MARK: Home screen

    private var homeScreenBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let resumable {
                Text(resumable.positionLabel)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WidgetPalette.text(scheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("Continue")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondary(scheme))
                Spacer(minLength: 0)
            } else {
                Text("How long do you have?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WidgetPalette.text(scheme))
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)

                // Two rows of two, mirroring Home's arrangement so the widget
                // reads as the same screen rather than a separate menu.
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        durationChip(.three)
                        durationChip(.ten)
                    }
                    HStack(spacing: 6) {
                        durationChip(.fifteen)
                        durationChip(.thirty)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Whole-widget fallback for the resume case; the chips carry their
        // own links otherwise.
        .widgetURL(resumable.map(resumeLink))
    }

    private func durationChip(_ window: TimeWindow) -> some View {
        let isLocked = lockedWindows.contains(window)
        return Link(destination: link(for: window)) {
            Text(window.shortLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    window == .thirty
                        ? WidgetPalette.textOnAccent(scheme)
                        : WidgetPalette.text(scheme)
                )
                .opacity(isLocked ? 0.55 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(window == .thirty ? WidgetPalette.accent(scheme) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            window == .thirty ? Color.clear : WidgetPalette.border(scheme),
                            // Dashed marks a locked length, exactly as on Home.
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: isLocked ? [4, 3] : []
                            )
                        )
                )
        }
        .accessibilityLabel(
            isLocked
                ? "\(window.label), \(window.format.displayName), Premium"
                : "\(window.label), \(window.format.displayName)"
        )
    }

    private var unlockedWindows: [TimeWindow] {
        let open = TimeWindow.allCases.filter { !lockedWindows.contains($0) }
        return open.isEmpty ? [.three, .ten] : open
    }

    /// A locked length routes to the paywall rather than to suggestions: a
    /// free user tapping "30 min" should get the honest answer, not a screen
    /// they can't act on.
    private func link(for window: TimeWindow) -> URL {
        let destination: WidgetDeepLink = lockedWindows.contains(window)
            ? .paywall(window)
            : .suggestions(window)
        return destination.url ?? URL(string: "spare://suggestions")!
    }

    private func resumeLink(_ course: WidgetSnapshot.ResumableCourse) -> URL {
        WidgetDeepLink
            .resumeCourse(lessonID: course.lessonID, chapterIndex: course.chapterIndex)
            .url ?? URL(string: "spare://suggestions")!
    }
}

// MARK: - Library count

/// Medium: "things I now know". Data as status, not a cartoon reward — the
/// same rule the Stats screen follows.
struct LibraryCountWidgetView: View {
    var snapshot: WidgetSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("THINGS I NOW KNOW")
                .font(.system(size: 11, weight: .semibold))
                .tracking(11 * 0.08)
                .foregroundStyle(WidgetPalette.secondary(scheme))

            if snapshot.isStorageReachable {
                Text("\(snapshot.thingsKnown)")
                    .font(.system(size: 44, weight: .semibold, design: .serif))
                    .foregroundStyle(WidgetPalette.accent(scheme))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(snapshot.thingsKnown == 1 ? "lesson finished" : "lessons finished")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondary(scheme))
            } else {
                // Never render an unreachable store as a zero — "0" is a
                // claim about the reader, and this is a claim about the app.
                Text("Open Spare once to set this up.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.suggestions(.ten).url)
        .accessibilityLabel(
            snapshot.isStorageReachable
                ? "\(snapshot.thingsKnown) lessons finished"
                : "Open Spare once to set up the widget"
        )
    }
}

private extension TimeWindow {
    /// "3", "10", "Course" — the widget has far less room than Home, so the
    /// unit is dropped from the numeric ones.
    var shortLabel: String {
        format.isChaptered ? "Course" : "\(minutes)"
    }
}
