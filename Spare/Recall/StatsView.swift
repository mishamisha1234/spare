import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import SpareCore

/// `UIImage` itself has no `Transferable` conformance — `ShareLink` needs an
/// explicit one, backed by PNG bytes rather than any in-memory `UIImage`
/// reference so the system share sheet (a separate process) can read it.
private struct ShareableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { shareable in
            shareable.image.pngData() ?? Data()
        }
    }
}

/// Points, level, achievements, and the domain fingerprint. Reached from the
/// quiet line in Library — deliberately not surfaced anywhere more
/// prominent, per the rule that points live on a screen the user visits,
/// not a counter shown everywhere.
struct StatsView: View {
    @Query(sort: \StoredLesson.generatedAt, order: .reverse)
    private var lessons: [StoredLesson]
    @Query private var pointEvents: [StoredPointEvent]

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingShareCard = false

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    private var completedLessons: [StoredLesson] {
        lessons.filter { $0.completedAt != nil }
    }

    private var events: [PointEvent] {
        pointEvents.map(\.event)
    }

    private var totalPoints: Int { PointsSummary.total(events) }
    private var minutesRead: Int {
        completedLessons.reduce(0) { $0 + $1.window.minutes }
    }

    private var librarySnapshot: LibrarySnapshot {
        LibrarySnapshot(
            completedLessonCount: completedLessons.count,
            completedMiniCourseCount: completedLessons.filter { $0.window == .thirty }.count,
            completedDomains: completedLessons.map(\.topicTag)
        )
    }

    private var achievements: [Achievement] {
        Achievements.unlocked(events: events, library: librarySnapshot)
    }

    private var shareData: ShareCardData {
        ShareCardData(
            lessons: completedLessons.map {
                // Labels are explicit: without them Swift infers `[Any]`
                // for a four-element tuple and the call stops compiling.
                (title: $0.title, domain: $0.topicTag, minutes: $0.window.minutes, generatedAt: $0.generatedAt)
            },
            events: events
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                statsSection
                if !achievements.isEmpty {
                    achievementsSection
                }
                shareSection
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingShareCard) {
            ShareCardPreview(data: shareData)
        }
        // No container-level accessibilityIdentifier: see OnboardingView.
    }

    /// Four plain lines. No level badge, no filling bar.
    ///
    /// Those were the "cartoons as reward" the brief rules out, and they
    /// shouldn't have been built — the underlying figures are fine, and are
    /// the same four the share card already computes.
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            statLine(value: "\(shareData.totalThings)", label: "things known", id: "stats.thingsKnown")
            statLine(value: "\(shareData.fieldsCovered)", label: "fields explored", id: "stats.fields")
            statLine(value: "\(minutesRead)", label: "minutes read", id: "stats.minutes")
            statLine(
                value: shareData.recallPercent.map { "\($0)%" } ?? "—",
                label: "recall",
                id: "stats.recall"
            )
        }
    }

    private func statLine(value: String, label: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(value)
                .font(Theme.Font.statValue.font)
                .foregroundStyle(palette.text)
            Text(label)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private var achievementsSection: some View {
        // No container-level accessibilityIdentifier: see OnboardingView —
        // confirmed elsewhere in this phase (RecallCardView) to clobber
        // every descendant's own identifier. Each row gets its own instead.
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("ACHIEVEMENTS")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)

            // One quiet line per achievement — no icons, no badges, no tiers.
            ForEach(achievements) { achievement in
                Text(achievement.title)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier("stats.achievement.\(achievement.id)")
            }
        }
    }

    private var shareSection: some View {
        Button {
            isShowingShareCard = true
        } label: {
            Text("Share")
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(palette.accent)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stats.share")
        .disabled(completedLessons.isEmpty)
    }
}

/// Renders `ShareCardView` to an image via `ImageRenderer` and shows it
/// full-screen before handing off to the system share sheet — a preview
/// step that doubles as the way this screen is verifiable from a CI
/// screenshot, since the rendered bitmap itself has no view hierarchy to
/// inspect otherwise.
private struct ShareCardPreview: View {
    let data: ShareCardData

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedImage: UIImage?

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        // No NavigationStack, and no ToolbarItem for Close.
        //
        // A sheet's dismiss control is not navigation: there is no back
        // gesture and no stack semantics behind it, so putting it in a
        // toolbar bought nothing and cost full control of its appearance —
        // iOS 26 renders toolbar items with glass chrome and a shadow. As
        // ordinary content it is styled from Theme like every other button.
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text("Share card")
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                Spacer()
                Button("Close") { dismiss() }
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("shareCard.close")
            }

            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("shareCard.image")

                ShareLink(
                    item: ShareableImage(image: renderedImage),
                    preview: SharePreview("Spare", image: Image(uiImage: renderedImage))
                ) {
                    // Accent, not the system blue this rendered in before —
                    // that was the only second colour anywhere in the app.
                    Text("Share")
                        .font(Theme.Font.headline.font)
                        .foregroundStyle(palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.ControlSize.button)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                .fill(palette.accent)
                        )
                }
                .accessibilityIdentifier("shareCard.shareLink")
            } else {
                ProgressView()
                    .tint(palette.accent)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
        .task { render() }
    }

    @MainActor
    private func render() {
        // Pinned to a fixed type size on purpose. The share card is a
        // fixed 9:16 artifact meant to leave the app, not a screen being
        // read — letting it inherit an accessibility text size would
        // overflow the four hero titles out of a bitmap nobody can scroll.
        // The reader's own text-size preference still governs every actual
        // screen, including this preview's surrounding chrome.
        let renderer = ImageRenderer(
            content: ShareCardView(data: data).environment(\.dynamicTypeSize, .large)
        )
        // scale 1, not the display scale: the card is specified in pixels
        // (1080 wide), and rendering at 1:1 makes the exported image exactly
        // those dimensions on every device rather than 2x or 3x of them.
        renderer.scale = 1
        renderedImage = renderer.uiImage
    }
}
