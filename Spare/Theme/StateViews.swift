import SwiftUI
import SpareCore

/// Nothing here yet — said plainly.
///
/// No illustration, no mascot, no exclamation. A line stating what's missing
/// and a line saying what fills it, in the same type the rest of the app uses.
struct EmptyStateView: View {
    let title: String
    let message: String
    var identifier: String?

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
            Text(message)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "state.empty")
    }
}

/// Something failed — said plainly, with an action only when one exists.
///
/// Retry is offered only for failures that retrying can actually fix, and
/// Settings only when the fix genuinely lives there. An action that can't
/// help implies the failure is the reader's fault for not trying hard enough.
struct ErrorStateView: View {
    let presentation: ErrorPresentation
    var onRetry: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var identifier: String = "state.error"

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(presentation.title)
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                Text(presentation.message)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if presentation.isRetryable, let onRetry {
                actionButton("Try again", action: onRetry)
                    .accessibilityIdentifier("\(identifier).retry")
            }
            if presentation.pointsToSettings, let onOpenSettings {
                actionButton("Open Settings", action: onOpenSettings)
                    .accessibilityIdentifier("\(identifier).settings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.headline.font)
                .foregroundStyle(palette.text)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.ControlSize.button)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
