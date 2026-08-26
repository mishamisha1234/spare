import SwiftUI
import SpareCore

/// What the reader sees when they dismiss the first paywall.
///
/// It announces a grant. It is not a second ask, and that is the whole reason
/// it exists: somebody who has just declined to pay is the worst possible
/// audience for another question, and the reverse trial's premise is that
/// giving them the week outright is what makes the *second* ask — seven days
/// later, about a library they built — a different question entirely.
///
/// So: no price, no plan rows, no "Maybe later". One button, and it says
/// "Start reading".
///
/// The cap is on the sheet, in the same sentence as the seven days. An
/// undisclosed cap is the App Review problem this project already fixed once,
/// and this one hands out Opus.
struct TrialOfferView: View {
    // No state of its own on purpose. The sheet is only ever shown after the
    // server has already granted the week, and what it says is built from the
    // same limits the server enforces -- so there is nothing here to get out
    // of step with. `TrialRulesTests` pins those limits to the server's.
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(TrialCopy.offerHeadline)
                        .font(Theme.Font.title.font)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trialOffer.headline")

                    Text(TrialCopy.offerBody)
                        .font(Theme.Font.body.font)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trialOffer.body")

                    Text(TrialCopy.offerCourseNote)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trialOffer.courseNote")
                }

                Button {
                    dismiss()
                } label: {
                    Text(TrialCopy.offerButton)
                        .font(Theme.Font.headline.font)
                        .foregroundStyle(palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.ControlSize.button)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                .fill(palette.accent)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trialOffer.start")

                // Stated because the absence of a card is the part people do
                // not believe. A reader who assumes they have entered a paid
                // trial will go looking for somewhere to cancel it, find
                // nothing, and assume the worst.
                Text("Nothing to cancel, and nothing renews.")
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
    }
}
