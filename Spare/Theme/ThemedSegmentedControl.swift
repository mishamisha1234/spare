import SwiftUI

/// A segmented control drawn from `Theme` tokens. The system `.segmented`
/// picker style ignores app theming entirely — it renders in the platform's
/// own gray capsule regardless of what `Theme` specifies — so it was the one
/// control left that could put an unthemed color or font on screen.
struct ThemedSegmentedControl<Option: Identifiable & Hashable>: View {
    var options: [Option]
    var label: (Option) -> String
    @Binding var selection: Option

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }
    private var segmentRadius: CGFloat { Theme.cornerRadius - Theme.borderWidth }

    var body: some View {
        // Four segments truncate to illegibility well before the largest
        // sizes, so past xxLarge this becomes a list of full-width rows with
        // a checkmark on the selected one.
        if dynamicTypeSize >= .xxLarge {
            verticalRows
        } else {
            segmented
        }
    }

    private var verticalRows: some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(label(option))
                            .font(Theme.Font.label.font)
                            .foregroundStyle(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(Theme.Font.caption.font)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minHeight: Theme.ControlSize.chip)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
        )
    }

    private var segmented: some View {
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
                        .frame(minHeight: Theme.ControlSize.chip)
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
                .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
        )
    }
}
