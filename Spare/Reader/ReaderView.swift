import SwiftUI
import SwiftData
import SpareCore

/// Full-bleed typography, generous margins, nothing else. No floating
/// buttons over the text, no highlight-and-share popovers.
struct ReaderView: View {
    @StateObject private var viewModel: ReaderViewModel
    var onContinue: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettingsKey.textSizeStep) private var textSizeStepRaw = TextSizeStep.standard.rawValue

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var textSizeStep: TextSizeStep { TextSizeStep(rawValue: textSizeStepRaw) ?? .standard }

    init(
        source: ReaderSource,
        provider: LessonProvider,
        modelContext: ModelContext,
        onContinue: @escaping (UUID) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(
            source: source, provider: provider, modelContext: modelContext
        ))
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            GeometryReader { outer in
                ScrollView {
                    content
                        .background(
                            GeometryReader { inner in
                                Color.clear
                                    .preference(key: ContentHeightKey.self, value: inner.size.height)
                                    .preference(
                                        key: ScrollOffsetKey.self,
                                        value: inner.frame(in: .named("reader.scroll")).minY
                                    )
                            }
                        )
                }
                .coordinateSpace(name: "reader.scroll")
                .onAppear { viewportHeight = outer.size.height }
                .onChange(of: outer.size.height) { _, newValue in viewportHeight = newValue }
            }
        }
        .background(palette.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if viewModel.isRevealed {
                    Text("\(viewModel.minutesRemaining) min left")
                        .font(Theme.Font.caption.font)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(TextSizeStep.allCases) { step in
                        Button {
                            textSizeStepRaw = step.rawValue
                        } label: {
                            if step == textSizeStep {
                                Label(step.label, systemImage: "checkmark")
                            } else {
                                Text(step.label)
                            }
                        }
                    }
                } label: {
                    Text("Aa")
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.text)
                }
                .accessibilityIdentifier("reader.textSize")
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(ScrollOffsetKey.self) { minY in
            let scrolled = max(0, -minY)
            let maxScroll = max(contentHeight - viewportHeight, 1)
            viewModel.updateScrollProgress(min(scrolled / maxScroll, 1))
        }
        .onAppear { viewModel.start() }
        // Leaving the Reader stops generation: an abandoned mini-course must
        // not keep drafting chapters nobody will read.
        .onDisappear { viewModel.stop() }
        // No container-level accessibilityIdentifier: see OnboardingView.
        // reader.continue / reader.holding / reader.textSize are what's used.
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.top, Theme.Spacing.xl)
            } else if !viewModel.isRevealed {
                holdingState
            } else {
                ForEach(viewModel.blocks) { block in
                    blockView(block)
                }

                if viewModel.isFinished {
                    continueButton
                } else {
                    Text("Still writing…")
                        .font(Theme.Font.caption.font)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.top, Theme.Spacing.s)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var holdingState: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView(value: viewModel.holdProgress)
                .tint(palette.accent)
            Text("Preparing your lesson…")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xl)
        .accessibilityIdentifier("reader.holding")
    }

    @ViewBuilder
    private func blockView(_ block: LessonBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(block.text)
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
                .padding(.top, Theme.Spacing.s)
        case .reflection:
            Text(block.text)
                .font(Theme.Font.scaledBody(multiplier: textSizeStep.multiplier))
                .italic()
                .foregroundStyle(palette.secondaryText)
        case .paragraph:
            Text(block.text)
                .font(Theme.Font.scaledBody(multiplier: textSizeStep.multiplier))
                .lineSpacing(Theme.Font.scaledBodyLineSpacing(multiplier: textSizeStep.multiplier))
                .foregroundStyle(palette.text)
        }
    }

    private var continueButton: some View {
        Button {
            if let id = viewModel.persistedLessonID { onContinue(id) }
        } label: {
            Text("Continue")
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.ControlSize.button)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(palette.accent))
        }
        .buttonStyle(.plain)
        .padding(.top, Theme.Spacing.m)
        .accessibilityIdentifier("reader.continue")
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(palette.border)
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: geo.size.width * viewModel.scrollProgress)
            }
        }
        .frame(height: Theme.ControlSize.progressBar)
    }
}

private struct ContentHeightKey: PreferenceKey {
    // `let`, not `var`: PreferenceKey's requirement is get-only, and a mutable
    // static var is exactly the "global shared mutable state" Swift 6 strict
    // concurrency rejects — anyone could reassign it from anywhere.
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
