import SwiftUI

/// A segmented control drawn from `Theme` tokens. The system `.segmented`
/// picker style ignores app theming entirely — it renders in the platform's
/// own gray capsule regardless of what `Theme` specifies — so it was the one
/// control left that could put an unthemed color or font on screen.
struct ThemedSegmentedControl<Option: Identifiable & Hashable>: View {
    var options: [Option]
    var label: (Option) -> String
    @Binding var selection: Option

    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var segmentRadius: CGFloat { Theme.cornerRadius - Theme.borderWidth }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(Theme.Font.label.font)
                        .foregroundStyle(isSelected ? palette.textOnAccent : palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(Theme.Interaction.chipLabelMinimumScale)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.ControlSize.chip)
                        .background(
                            RoundedRectangle(cornerRadius: segmentRadius)
                                .fill(isSelected ? palette.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.borderWidth)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
        )
    }
}
