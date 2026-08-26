#if DEBUG
import SwiftUI
import SpareCore

/// The trial funnel, for this device, in a build nobody ships.
///
/// DEBUG-only and reachable only from Settings, because it is a wiring check
/// rather than a statistic about the reader. What it proves is that the six
/// events are being recorded at the moments they should be; what it cannot do
/// is answer §6's question.
///
/// That limit is stated on the screen rather than left implicit. §6 asks for
/// *"the percentage of users who dismiss the day-0 paywall and then complete 3
/// or more lessons"*, and a percentage needs a denominator that spans devices.
/// One device can only say yes or no for itself. The share lives on the
/// server, in five integers with no identifiers attached, and is read through
/// the authenticated `/v1/status`.
struct FunnelDebugView: View {
    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.colorScheme) private var colorScheme

    @State private var counts = FunnelCounts()

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                section("This device") {
                    row("Paywalls shown", counts.paywallsShown)
                    row("Dismissed without buying", counts.paywallsDismissed)
                    row("Trials started", counts.trialsStarted)
                    row("Lessons read during a trial", counts.trialLessonsCompleted)
                    row("Trials ended", counts.trialsEnded)
                    row("Purchases", counts.conversions)
                }

                section("The one number") {
                    Text(verdict)
                        .font(Theme.Font.body.font)
                        .foregroundStyle(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("debug.funnel.verdict")

                    Text(
                        "One device answers yes or no; the share across devices is five "
                            + "integers on the server, with no identifiers attached to them. "
                            + "Read it with GET /v1/status. Above "
                            + "\(FunnelThresholds.healthyPercent)% the model works and the lever "
                            + "is pricing; under \(FunnelThresholds.unhealthyPercent)% the "
                            + "lessons are not good enough and no pricing change fixes that."
                    )
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                section("Trial state") {
                    row("Status", entitlements.snapshot.trial.status.rawValue)
                    row("Lessons left", entitlements.trialLessonsRemaining)
                    row("Days left", entitlements.trialDaysRemaining())
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .navigationTitle("Trial funnel")
        .navigationBarTitleDisplayMode(.inline)
        .task { counts = entitlements.funnelCounts() }
    }

    private var verdict: String {
        switch counts.didEngageAfterDismissal {
        case nil:
            return "No paywall has been dismissed on this device yet, so there is nothing "
                + "to be a share of."
        case true?:
            return "This device dismissed the paywall and then read "
                + "\(counts.trialLessonsCompleted) lessons — it counts toward the numerator."
        case false?:
            return "This device dismissed the paywall and read "
                + "\(counts.trialLessonsCompleted) of the \(FunnelThresholds.engagedLessons) "
                + "lessons that count as having tried it."
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title.uppercased())
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
            content()
        }
    }

    private func row(_ label: String, _ value: some CustomStringConvertible) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Font.body.font)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.xs)
            Text(String(describing: value))
                .font(Theme.Font.body.font)
                .foregroundStyle(palette.secondaryText)
        }
    }
}
#endif
