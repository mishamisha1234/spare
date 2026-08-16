import SwiftUI
import SpareCore

/// The paywall.
///
/// Every value here comes from `Theme` — no bespoke gradient, no accent
/// colour invented for this screen, no larger type scale than the rest of
/// the app uses. It should read as the same product as the Reader.
///
/// Copy rules, deliberately: no countdown, no "limited time", no strike-through
/// on a price that was never charged, no framing that implies the reader is
/// failing at something. The yearly saving is the only comparative claim, it
/// is computed from the two real prices, and it rounds down.
struct PaywallView: View {
    let trigger: PaywallTrigger

    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selected: PurchaseProductKind = .yearly

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    header
                    options
                    footer
                }
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.background)
            .navigationTitle("Spare Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(palette.text)
                        .accessibilityIdentifier("paywall.close")
                }
            }
        }
        .task { await entitlements.loadProducts() }
        // Dismiss as soon as the purchase lands, rather than showing a
        // congratulations screen nobody asked for.
        .onChange(of: entitlements.isPremium) { _, isPremium in
            if isPremium { dismiss() }
        }
    }

    // MARK: - Header

    /// Names the specific thing the reader just hit, rather than opening with
    /// a generic pitch. They tapped something concrete; answer that.
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(Self.headline(for: trigger))
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("paywall.headline")

            Text("Premium removes the daily limit, unlocks every length, keeps your whole library, and adds the post-lesson test.")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func headline(for trigger: PaywallTrigger) -> String {
        switch trigger {
        case .dailyLimitReached:
            "That's today's free lesson."
        case .lockedWindow(let window):
            "\(window.label) lessons are part of Premium."
        case .goDeeperLocked:
            "Going deeper is part of Premium."
        case .postLessonTestLocked:
            "The post-lesson test is part of Premium."
        }
    }

    // MARK: - Options

    @ViewBuilder
    private var options: some View {
        if entitlements.products.isEmpty {
            // Honest empty state rather than a spinner that never resolves.
            Text(entitlements.isLoadingProducts
                 ? "Loading options…"
                 : "Couldn't load purchase options. Check your connection and try again.")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("paywall.optionsUnavailable")
        } else {
            VStack(spacing: Theme.Spacing.xs) {
                ForEach(entitlements.products) { product in
                    optionRow(product)
                }
            }
        }
    }

    private func optionRow(_ product: PurchaseProduct) -> some View {
        let isSelected = product.kind == selected
        return Button {
            selected = product.kind
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(product.displayName)
                        .font(Theme.Font.headline.font)
                        .foregroundStyle(palette.text)

                    if let detail = detail(for: product) {
                        Text(detail)
                            .font(Theme.Font.caption.font)
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer(minLength: Theme.Spacing.xs)

                Text(product.displayPrice)
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
            }
            .padding(Theme.Spacing.s)
            .frame(minHeight: Theme.ControlSize.optionRow)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(
                        isSelected ? palette.accent : palette.border,
                        lineWidth: Theme.borderWidth
                    )
            )
            // Stroke-only backgrounds aren't hit-testable in their interior;
            // see RecallCardView for the confirmed failure this prevents.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall.option.\(product.kind.rawValue)")
    }

    /// The per-month equivalent and saving for the yearly plan; the honest
    /// "one payment" note for lifetime. Both derived, never hardcoded — if a
    /// price changes in App Store Connect these follow it.
    private func detail(for product: PurchaseProduct) -> String? {
        switch product.kind {
        case .monthly:
            return "Cancel anytime."
        case .yearly:
            let perMonth = PricingSummary.perMonth(yearly: product.price)
            var text = "\(currency(perMonth, like: product.displayPrice)) a month, billed yearly."
            if let monthly = entitlements.products.first(where: { $0.kind == .monthly }),
               let saving = PricingSummary.savingPercent(yearly: product.price, monthly: monthly.price) {
                text += " Save \(saving)%."
            }
            return text
        case .lifetime:
            return "One payment, yours for good."
        }
    }

    /// Formats a derived amount using the currency symbol StoreKit already
    /// gave us, so a computed per-month figure matches the real prices
    /// beside it instead of guessing at the user's locale.
    private func currency(_ amount: Decimal, like displayPrice: String) -> String {
        let symbol = displayPrice.prefix { !$0.isNumber && $0 != "-" }
        let number = NSDecimalNumber(decimal: amount).doubleValue
        return "\(symbol)\(String(format: "%.2f", number))"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button {
                Task { await entitlements.purchase(selected) }
            } label: {
                Text(entitlements.isPurchasing ? "Working…" : "Continue")
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
            .disabled(entitlements.products.isEmpty || entitlements.isPurchasing)
            .accessibilityIdentifier("paywall.buy")

            Button {
                Task { await entitlements.restore() }
            } label: {
                Text(entitlements.isRestoring ? "Restoring…" : "Restore purchases")
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(entitlements.isRestoring)
            .accessibilityIdentifier("paywall.restore")

            if let error = entitlements.errorMessage {
                Text(error)
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.error")
            }

            Text(selected.isSubscription
                 ? "Renews automatically until cancelled. Manage or cancel in your Apple Account settings."
                 : "A single purchase. No subscription, nothing to cancel.")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
