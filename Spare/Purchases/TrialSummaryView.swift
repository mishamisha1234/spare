import SwiftUI
import SwiftData
import SpareCore

/// The first thing the reader sees after the free week ends.
///
/// The whole selling model is in this screen. The first ask was about an app
/// they had used once; this one is about a library they built, a habit they
/// have, and questions they got right — which is a different decision, and the
/// only reason the trial is worth what it costs to give away.
///
/// Two rules it has to keep:
///
/// - **Every number is theirs and is true.** A padded figure here is the one
///   place the pitch would stop matching the product, and it is the moment the
///   reader is most likely to be checking. Clauses with nothing true to say are
///   dropped rather than filled in; see `TrialCopy.summaryLine`.
/// - **Nothing has been taken away.** The free tier keeps the whole library and
///   keeps recall running, and the screen says so before it says anything about
///   money. Loss aversion works because there is something to keep, not because
///   something is being held hostage.
struct TrialSummaryView: View {
    let summary: TrialSummary
    /// Opens the paywall. Called after this sheet dismisses, so the two sheets
    /// do not collide -- see `RootView`.
    var onKeepPremium: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(TrialCopy.summaryHeadline)
                        .font(Theme.Font.title.font)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trialSummary.headline")

                    Text(TrialCopy.summaryLine(summary))
                        .font(Theme.Font.body.font)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("trialSummary.line")
                }

                // Before the ask, not after it.
                Text(TrialCopy.summaryFreeTierNote)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trialSummary.freeTierNote")

                VStack(spacing: Theme.Spacing.s) {
                    Button {
                        onKeepPremium()
                    } label: {
                        Text(TrialCopy.summaryPrimaryButton)
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
                    .accessibilityIdentifier("trialSummary.keepPremium")

                    // A real second option, weighted as one. Continuing on
                    // Free is not a failure state and is not styled as one:
                    // a meaningful share of freemium conversions land six or
                    // more weeks after install, and a reader pushed out here
                    // is not one of them.
                    Button {
                        dismiss()
                    } label: {
                        Text(TrialCopy.summarySecondaryButton)
                            .font(Theme.Font.label.font)
                            .foregroundStyle(palette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Theme.ControlSize.button)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trialSummary.continueFree")
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
    }
}
