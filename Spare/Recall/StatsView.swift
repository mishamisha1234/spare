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
    private var level: Int { Level.level(forPoints: totalPoints) }
    private var progress: Double { Level.progressToNextLevel(forPoints: totalPoints) }

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
            lessons: completedLessons.map { ($0.title, $0.topicTag, $0.generatedAt) },
            events: events
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                pointsSection
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

    private var pointsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Level \(level)")
                .font(Theme.Font.largeTitle.font)
                .foregroundStyle(palette.text)
                .accessibilityIdentifier("stats.level")

            Text("\(totalPoints) points")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                .accessibilityIdentifier("stats.points")

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.border)
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: Theme.ControlSize.progressBar)
        }
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
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
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
    @Environment(\.displayScale) private var displayScale
    @State private var renderedImage: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.m) {
                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320)
                        .accessibilityIdentifier("shareCard.image")

                    ShareLink(
                        item: ShareableImage(image: renderedImage),
                        preview: SharePreview("Spare", image: Image(uiImage: renderedImage))
                    ) {
                        Text("Share")
                            .font(Theme.Font.headline.font)
                    }
                    .accessibilityIdentifier("shareCard.shareLink")
                } else {
                    ProgressView()
                }
            }
            .padding(Theme.Spacing.m)
            .navigationTitle("Share card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("shareCard.close")
                }
            }
        }
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
        renderer.scale = displayScale
        renderedImage = renderer.uiImage
    }
}
