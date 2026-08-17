import SwiftUI
import SwiftData
import SpareCore

/// "Things I now know" — a chronological, visibly growing list. Grouped by
/// month. Filterable by domain.
struct LibraryView: View {
    var onSelect: (StoredLesson) -> Void
    var onOpenStats: () -> Void
    /// Sends an empty library back to Home to choose a duration.
    var onPickLength: () -> Void

    @Query(sort: \StoredLesson.generatedAt, order: .reverse)
    private var lessons: [StoredLesson]
    @EnvironmentObject private var entitlements: EntitlementService
    @Query private var pointEvents: [StoredPointEvent]

    @State private var selectedDomain: String?
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    /// Full history, not `visibleLessons`: an achievement reflects what was
    /// actually done, regardless of what the free-tier cap currently hides.
    private var achievementCount: Int {
        let completed = lessons.filter { $0.completedAt != nil }
        let library = LibrarySnapshot(
            completedLessonCount: completed.count,
            completedMiniCourseCount: completed.filter { $0.window == .thirty }.count,
            completedDomains: completed.map(\.topicTag)
        )
        return Achievements.unlocked(events: pointEvents.map(\.event), library: library).count
    }

    /// The free tier hides — never deletes — everything past the most
    /// recent 10 entries. The rule itself lives in `EntitlementService`;
    /// this view only asks.
    private var visibleLessons: [StoredLesson] {
        Array(lessons.prefix(entitlements.visibleLibraryCount(totalEntries: lessons.count)))
    }

    private var hiddenCount: Int {
        entitlements.hiddenLibraryCount(totalEntries: lessons.count)
    }

    private var domains: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for lesson in visibleLessons where !seen.contains(lesson.topicTag) {
            seen.insert(lesson.topicTag)
            ordered.append(lesson.topicTag)
        }
        return ordered
    }

    private var filteredLessons: [StoredLesson] {
        guard let selectedDomain else { return visibleLessons }
        return visibleLessons.filter { $0.topicTag == selectedDomain }
    }

    /// Filtered lessons grouped into month sections, preserving the
    /// newest-first order already established by the query's sort.
    private var monthGroups: [(month: String, lessons: [StoredLesson])] {
        var groups: [(month: String, lessons: [StoredLesson])] = []
        for lesson in filteredLessons {
            let month = lesson.generatedAt.formatted(.dateTime.month(.wide).year())
            if groups.last?.month == month {
                groups[groups.count - 1].lessons.append(lesson)
            } else {
                groups.append((month, [lesson]))
            }
        }
        return groups
    }

    var body: some View {
        Group {
            if lessons.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        statsLine

                        if !domains.isEmpty {
                            domainFilter
                        }

                        ForEach(monthGroups, id: \.month) { group in
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(group.month.uppercased())
                                        .font(Theme.Font.caption.font)
                                        .foregroundStyle(palette.secondaryText)
                                    // The collection counted, under the month
                                    // it belongs to. Completion already calls
                                    // these "things I now know"; the library
                                    // should be the same object, counted.
                                    Text(Self.thingsCount(group.lessons.count))
                                        .font(Theme.Font.label.font)
                                        .foregroundStyle(palette.secondaryText)
                                }
                                .padding(.horizontal, Theme.Spacing.m)

                                VStack(spacing: 0) {
                                    ForEach(Array(group.lessons.enumerated()), id: \.element.id) { index, lesson in
                                        row(lesson)
                                            .onTapGesture { onSelect(lesson) }
                                        if index < group.lessons.count - 1 {
                                            Divider().overlay(palette.border)
                                                .padding(.horizontal, Theme.Spacing.m)
                                        }
                                    }
                                }
                            }
                        }

                        if hiddenCount > 0 {
                            // "hidden, not deleted" is a factual claim, and it
                            // is true: nothing in this app ever deletes a
                            // lesson. `visibleLibraryCount` caps what is
                            // shown; the query behind it is unfiltered, so
                            // upgrading restores every entry.
                            Text("Free keeps your last \(EntitlementRules.freeLibraryLimit). Older entries are hidden, not deleted.")
                                .font(Theme.Font.caption.font)
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Theme.Spacing.m)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.m)
                }
            }
        }
        .background(palette.background)
        .navigationTitle("Things I know")
        .toolbar {
            if !lessons.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    // Exports the *whole* library, not the free-tier-visible
                    // slice: the cap hides entries, it doesn't unmake them,
                    // and an export that silently dropped someone's older
                    // lessons would be a data-loss trap rather than a limit.
                    ShareLink(
                        item: exportDocument,
                        preview: SharePreview(MarkdownExport.filename())
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(palette.text)
                    .accessibilityLabel("Share your library as Markdown")
                    .accessibilityIdentifier("library.export")
                }
            }
        }
        // No container-level accessibilityIdentifier: see OnboardingView.
        // library.filter.*, library.row.*, and library.empty are what's used.
    }

    private var exportDocument: MarkdownLibraryDocument {
        MarkdownLibraryDocument(
            text: MarkdownExport.document(lessons: lessons.map(\.exportable))
        )
    }

    /// The one place achievements surface: a single quiet line of text, not
    /// a badge or a counter. Always present, even with zero achievements
    /// yet, so Stats stays reachable from launch.
    private var statsLine: some View {
        // A row, not a bare label: as a lone line of secondary text it read
        // as a section header for the filter chips underneath it.
        Button(action: onOpenStats) {
            HStack {
                Text(statsLineText)
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: Theme.ControlSize.button)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.stats")
    }

    private var statsLineText: String {
        achievementCount == 0
            ? "Stats"
            : "\(achievementCount) achievement\(achievementCount == 1 ? "" : "s") unlocked"
    }

    private var domainFilter: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.xs) {
                filterChip("All", isSelected: selectedDomain == nil) { selectedDomain = nil }
                ForEach(domains, id: \.self) { domain in
                    filterChip(domain, isSelected: selectedDomain == domain) { selectedDomain = domain }
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
        .scrollIndicators(.hidden)
    }

    private func filterChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.label.font)
                .foregroundStyle(isSelected ? palette.textOnAccent : palette.text)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.ControlSize.filterChip)
                .background(Capsule().fill(isSelected ? palette.accent : Color.clear))
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : palette.borderInteractive,
                        lineWidth: Theme.borderWidth
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.filter.\(title)")
    }

    private func row(_ lesson: StoredLesson) -> some View {
        // Same component as a Suggestions row, so the same scan order:
        // tag, then title. These were reading in opposite directions.
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(lesson.topicTag.uppercased())
                .font(Theme.Font.eyebrow.font)
                .tracking(Theme.Font.eyebrow.tracking)
                .foregroundStyle(palette.secondaryText)
            Text(lesson.title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
        .accessibilityIdentifier("library.row.\(lesson.id)")
    }

    static func thingsCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "thing" : "things")"
    }

    private var emptyState: some View {
        EmptyStateView(
            title: "Nothing here yet.",
            message: "Finished lessons land here.",
            actionTitle: "Pick a length",
            action: onPickLength,
            identifier: "library.empty"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
