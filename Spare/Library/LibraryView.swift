import SwiftUI
import SwiftData
import SpareCore

/// "Things I now know" — a chronological, visibly growing list. Grouped by
/// month. Filterable by domain.
struct LibraryView: View {
    var onSelect: (StoredLesson) -> Void

    @Query(sort: \StoredLesson.generatedAt, order: .reverse)
    private var lessons: [StoredLesson]
    @Query private var entitlements: [StoredEntitlement]

    @State private var selectedDomain: String?
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    private var entitlementSnapshot: EntitlementSnapshot {
        entitlements.first?.snapshot ?? .free
    }

    /// The free tier hides — never deletes — everything past the most
    /// recent 10 entries.
    private var visibleLessons: [StoredLesson] {
        let count = EntitlementRules.visibleLibraryCount(entitlementSnapshot, totalEntries: lessons.count)
        return Array(lessons.prefix(count))
    }

    private var hiddenCount: Int {
        EntitlementRules.hiddenLibraryCount(entitlementSnapshot, totalEntries: lessons.count)
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
        .accessibilityIdentifier("library.screen")
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
                .frame(height: Theme.ControlSize.filterChip)
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
