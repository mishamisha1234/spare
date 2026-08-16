import SwiftUI
import SwiftData
import SpareCore

/// "Things I now know" — a chronological, visibly growing list. Grouped by
/// month. Filterable by domain.
struct LibraryView: View {
    var onSelect: (StoredLesson) -> Void
    var onOpenStats: () -> Void

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
                                Text(group.month.uppercased())
                                    .font(Theme.Font.caption.font)
                                    .foregroundStyle(palette.secondaryText)
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
                            Text("\(hiddenCount) earlier \(hiddenCount == 1 ? "lesson" : "lessons") hidden on the free plan")
                                .font(Theme.Font.caption.font)
                                .foregroundStyle(palette.secondaryText)
                                .padding(.horizontal, Theme.Spacing.m)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.m)
                }
            }
        }
        .background(palette.background)
        .navigationTitle("Library")
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
                    .accessibilityLabel("Export library as Markdown")
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
        Button(action: onOpenStats) {
            Text(statsLineText)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Spacing.m)
        .accessibilityIdentifier("library.stats")
    }

    private var statsLineText: String {
        achievementCount == 0
            ? "Stats"
            : "\(achievementCount) achievement\(achievementCount == 1 ? "" : "s") unlocked"
    }

    private var domainFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                filterChip("All", isSelected: selectedDomain == nil) { selectedDomain = nil }
                ForEach(domains, id: \.self) { domain in
                    filterChip(domain, isSelected: selectedDomain == domain) { selectedDomain = domain }
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
    }

    private func filterChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.label.font)
                .foregroundStyle(isSelected ? palette.textOnAccent : palette.text)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.ControlSize.filterChip)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(isSelected ? palette.accent : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(isSelected ? Color.clear : palette.border, lineWidth: Theme.borderWidth)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.filter.\(title)")
    }

    private func row(_ lesson: StoredLesson) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(lesson.title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
            Text(lesson.topicTag.uppercased())
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
        .accessibilityIdentifier("library.row.\(lesson.id)")
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text("Nothing yet")
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
            Text("Finish a lesson and it will show up here.")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.empty")
    }
}
