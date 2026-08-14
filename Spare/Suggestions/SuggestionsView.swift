import SwiftUI
import SwiftData
import SpareCore

struct SuggestionsView: View {
    @StateObject private var viewModel: SuggestionsViewModel
    var onSelect: (TopicSuggestion) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    init(
        window: TimeWindow,
        provider: LessonProvider,
        modelContext: ModelContext,
        onSelect: @escaping (TopicSuggestion) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: SuggestionsViewModel(
            window: window, provider: provider, modelContext: modelContext
        ))
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    row(suggestion)
                        .onTapGesture { onSelect(suggestion) }
                    if index < viewModel.suggestions.count - 1 {
                        Divider().overlay(palette.border)
                    }
                }

                if viewModel.suggestions.isEmpty, viewModel.isRefreshing {
                    ProgressView()
                        .tint(palette.accent)
                        .padding(.top, Theme.Spacing.l)
                }
                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
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
            }
        }
        .task { await viewModel.loadCacheThenRefresh() }
        // No container-level accessibilityIdentifier: see OnboardingView.
        // suggestions.row.* and suggestions.shuffle are what's used.
    }

    private func row(_ suggestion: TopicSuggestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(suggestion.title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
            Text(suggestion.hook)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
            Text(suggestion.domainTag.uppercased())
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
                .padding(.top, Theme.Spacing.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.s)
        .contentShape(Rectangle())
        .accessibilityIdentifier("suggestions.row.\(suggestion.id)")
    }
}
