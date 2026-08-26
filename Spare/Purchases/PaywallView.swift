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

    /// What the free tier actually gives, in one sentence.
    ///
    /// Built from `EntitlementRules` rather than written out, and pinned by
    /// `PaywallCopyTests`, because this sentence is a promise: it appears on the
    /// paywall and it is the wording the App Store listing follows. It was
    /// briefly untrue in a direction nobody would have noticed — cached lessons
    /// were served without counting against the daily allowance, so free users
    /// got more than one a day and the more popular a topic became the more they
    /// got. The server now meters every lesson whatever its source, which is
    /// what makes this sentence accurate again.
    static var freeTierDisclosure: String {
        let lessons = EntitlementRules.freeLessonsPerDay == 1
            ? "one lesson a day"
            : "\(EntitlementRules.freeLessonsPerDay) lessons a day"
        return "Free gives you the 3- and 7-minute lengths, \(lessons), and your whole library — nothing you have learned is ever hidden or deleted."
    }

    /// What Premium adds, in one sentence.
    ///
    /// It used to open with "keeps your whole library", back when the free
    /// tier showed only its most recent ten entries. Free now keeps the whole
    /// library too, so that clause would be selling something the reader
    /// already has — a false differentiator rather than a false fact, but it
    /// is still the sheet claiming a benefit that isn't one.
    ///
    /// Names the mini-course cap for the original reason: selling "unlocks
    /// every length" while Settings shows "11 of 12 mini-courses left this
    /// month" is a limit disclosed only after purchase, which is an App
    /// Review problem before it is a copy problem.
    static var premiumPitch: String {
        "Premium unlocks every length, adds the post-lesson test and going deeper, "
            + "and gives you \(EntitlementRules.premiumMiniCoursesPerMonth) mini-courses a month. "
            + "Shorter lessons are unlimited."
    }

    let trigger: PaywallTrigger

    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    /// Yearly at every entry point, and stated here rather than inferred from
    /// the enum's order: it was once defaulting to whichever plan happened to
    /// come first, so two different triggers opened on two different plans.
    /// It is also the plan carrying the introductory first year.
    @State private var selected: PurchaseProductKind = .yearly

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    var body: some View {
        // No NavigationStack, and Close is ordinary content rather than a
        // ToolbarItem — a sheet's dismiss control carries no navigation
        // semantics, and in a toolbar it picks up iOS 26's glass chrome and
        // shadow with no way to opt out.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                HStack {
                    Text("Spare Premium")
                        .font(Theme.Font.headline.font)
                        .foregroundStyle(palette.text)
                    Spacer()
                    Button("Close") { dismiss() }
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("paywall.close")
                }

                header
                options
                footer
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .task { await entitlements.loadProducts() }
        // Dismiss as soon as the purchase lands, rather than showing a
        // congratulations screen nobody asked for.
        .onChange(of: entitlements.hasPremiumAccess) { _, hasPremiumAccess in
            if hasPremiumAccess { dismiss() }
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

            Text(Self.premiumPitch)
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                // What they'd be giving up, visible without leaving the sheet.
                Text(Self.freeTierDisclosure)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Spacing.xxs)

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
            // Title-leading / price-trailing collides once the title wraps,
            // so past AX1 the row stacks instead.
            Group {
                if dynamicTypeSize >= .accessibility1 {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(product.displayName)
                            .font(Theme.Font.headline.font)
                            .foregroundStyle(palette.text)
                        Text(product.displayPrice)
                            .font(Theme.Font.headline.font)
                            .foregroundStyle(palette.text)
                        if let detail = detail(for: product) {
                            Text(detail)
                                .font(Theme.Font.caption.font)
                                .foregroundStyle(palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(product.displayName)
                                .font(Theme.Font.headline.font)
                                .foregroundStyle(palette.text)

                            if let detail = detail(for: product) {
                                Text(detail)
                                    .font(Theme.Font.caption.font)
                                    .foregroundStyle(palette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer(minLength: Theme.Spacing.xs)

                        Text(product.displayPrice)
                            .font(Theme.Font.headline.font)
                            .foregroundStyle(palette.text)
                    }
                }
            }
            .padding(Theme.Spacing.s)
            .frame(minHeight: Theme.ControlSize.optionRow)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(
                        isSelected ? palette.accent : palette.borderInteractive,
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

    /// The per-month equivalent, the annual saving, and — when this account
    /// is eligible for it — the first-year price. All derived, never
    /// hardcoded: if a price changes in App Store Connect these follow it.
    ///
    /// The two discounts are stated separately and never multiplied. "Save
    /// 42%" compares the annual plan to twelve monthly payments; "50% off
    /// your first year" compares year one to year two. Combining them would
    /// produce a percentage larger than either is, out of two prices that
    /// are individually true.
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
            if let intro = product.introductoryOffer {
                // Both prices, in order, in one sentence. A first-year price
                // shown without what it reverts to is the thing people mean
                // by a dark pattern.
                text += " \(intro.displayPrice) for your first year, then \(product.displayPrice)."
                if let off = PricingSummary.introductorySavingPercent(
                    introductory: intro.price, standard: product.price
                ) {
                    text += " \(off)% off year one."
                }
            }
            return text
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

    private var selectedProduct: PurchaseProduct? {
        entitlements.products.first(where: { $0.kind == selected })
    }

    /// The auto-renewal sentence. Both products renew now that there is no
    /// one-off purchase, so the only variation left is whether a first year
    /// at a different price has to be named before the renewal price.
    static func renewalDisclosure(for product: PurchaseProduct?) -> String {
        let base = "Manage or cancel in your Apple Account settings."
        guard let product, let intro = product.introductoryOffer else {
            return "Renews automatically until cancelled. " + base
        }
        return "\(intro.displayPrice) for the first year, then \(product.displayPrice) a year, "
            + "renewing automatically until cancelled. " + base
    }

    /// Names the plan and its price rather than saying "Continue" — the
    /// reader should know what they are about to be charged before the
    /// system sheet appears, not after.
    private var purchaseButtonTitle: String {
        if entitlements.isPurchasing { return "Working…" }
        guard let product = selectedProduct else {
            return "Continue"
        }
        switch product.kind {
        case .monthly:
            return "Continue — \(product.displayPrice) a month"
        case .yearly:
            // The amount about to be charged, which for an eligible account
            // is the introductory price and not the headline one. The
            // renewal price is stated in the row above and in the footer;
            // the button has to be true about *this* transaction.
            if let intro = product.introductoryOffer {
                return "Continue — \(intro.displayPrice) for your first year"
            }
            return "Continue — \(product.displayPrice) a year"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button {
                Task { await entitlements.purchase(selected) }
            } label: {
                Text(purchaseButtonTitle)
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

            Text(Self.renewalDisclosure(for: selectedProduct))
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
