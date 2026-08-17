import SwiftUI
import SwiftData
import SpareCore

struct SuggestionsView: View {
    @StateObject private var viewModel: SuggestionsViewModel
    var onSelect: (TopicSuggestion) -> Void
    /// Offered only when a failure's fix genuinely lives in Settings — a
    /// missing or rejected API key.
    var onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    init(
        window: TimeWindow,
        provider: LessonProvider,
        modelContext: ModelContext,
        onSelect: @escaping (TopicSuggestion) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: SuggestionsViewModel(
            window: window, provider: provider, modelContext: modelContext
        ))
        self.onSelect = onSelect
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    row(suggestion)
                        .onTapGesture { onSelect(suggestion) }
                    if index < viewModel.suggestions.count - 1 {
                        // Inset from the leading edge only, so the rows read
                        // as a list rather than as separate cards.
                        Divider()
                            .overlay(palette.border)
                            .padding(.leading, Theme.Spacing.m)
                    }
                }

                if viewModel.suggestions.isEmpty, viewModel.isRefreshing {
                    ProgressView()
                        .tint(palette.accent)
                        .padding(.top, Theme.Spacing.l)
                }

                if let failure = viewModel.failure {
                    ErrorStateView(
                        presentation: failure,
                        onRetry: { Task { await viewModel.shuffle() } },
                        onOpenSettings: onOpenSettings,
                        identifier: "suggestions.error"
                    )
                    .padding(.top, Theme.Spacing.l)
                } else if viewModel.suggestions.isEmpty, !viewModel.isRefreshing {
                    // Distinct from a failure: nothing came back, but nothing
                    // broke either. Shuffling is the honest next move.
                    EmptyStateView(
                        title: "Nothing came back for \(viewModel.window.label).",
                        message: "Try another length, or shuffle.",
                        actionTitle: "Shuffle",
                        action: { Task { await viewModel.shuffle() } },
                        identifier: "suggestions.empty"
                    )
                    .padding(.top, Theme.Spacing.l)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
        .background(palette.background)
        .navigationTitle(viewModel.window.label)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.shuffle() }
                } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.text)
                .accessibilityIdentifier("suggestions.shuffle")
                .accessibilityLabel("Shuffle these suggestions")
            }
        }
        .task { await viewModel.loadCacheThenRefresh() }
        // No container-level accessibilityIdentifier: see OnboardingView.
        // suggestions.row.* and suggestions.shuffle are what's used.
    }

    private func row(_ suggestion: TopicSuggestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            // Tag leads as an eyebrow, not a footnote: scan order is
            // tag → title → hook, and the tag needs to outrank the hook.
            Text(suggestion.domainTag.uppercased())
                .font(Theme.Font.eyebrow.font)
                .tracking(Theme.Font.eyebrow.tracking)
                .foregroundStyle(palette.text)
            Text(suggestion.title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
            Text(suggestion.hook)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                // Capped so five rows stay on one screen at Large text.
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.rowVertical)
        .contentShape(Rectangle())
        .accessibilityIdentifier("suggestions.row.\(suggestion.id)")
    }
}
