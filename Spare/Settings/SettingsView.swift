import SwiftUI
import SwiftData
import SpareCore

/// API key entry, reading preferences, and what the key has cost this month.
struct SettingsView: View {

    @Query(sort: \StoredUsageEvent.occurredAt, order: .reverse)
    private var usageEvents: [StoredUsageEvent]

    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = Theme.AppearanceMode.system.rawValue
    @AppStorage(AppSettingsKey.textSizeStep) private var textSizeStepRaw = TextSizeStep.standard.rawValue
    @AppStorage(AppSettingsKey.recallNotificationTimeMinutes) private var recallNotificationTimeMinutes = NotificationScheduler.defaultMinutesSinceMidnight

    @EnvironmentObject private var entitlements: EntitlementService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var keyEntry = ""
    @State private var hasStoredKey = false
    @State private var statusMessage: String?

    private let keyStore = KeychainAPIKeyStore()
    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    private var monthTotal: Double {
        UsageSummary.monthTotal(usageEvents.map(\.event), containing: Date())
    }

    private var allTimeTotal: Double {
        UsageSummary.total(usageEvents.map(\.event))
    }

    /// `DatePicker` wants a `Date`; the stored preference is minutes since
    /// midnight, since that's all a daily reminder time actually is — no
    /// calendar day is meaningful to persist alongside it.
    private var recallTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: recallNotificationTimeMinutes / 60,
                    minute: recallNotificationTimeMinutes % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                recallNotificationTimeMinutes = (components.hour ?? 9) * 60 + (components.minute ?? 0)
                NotificationScheduler.reschedule(modelContext: modelContext)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                planSection
                // Excluded from Release. Asking a consumer to paste a secret
                // key is a review risk and a support burden; it exists for
                // development and manual API verification only.
                #if DEBUG
                apiKeySection
                #endif
                readingSection
                reminderSection
                widgetSection
                usageSection
                aboutSection
                // Excluded from Release for the same reason the API key field
                // is: it exists to confirm the funnel events fire at the right
                // moments, and it is not a statistic about the reader.
                #if DEBUG
                funnelDebugSection
                #endif
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { hasStoredKey = await keyStore.currentKey() != nil }
    }

    // MARK: - Plan

    /// States the plan and whatever allowance applies to it — before it bites
    /// rather than at the moment it does. A cap discovered only on refusal is
    /// a worse deal than the same cap stated up front.
    ///
    /// Three states, not two. A trialist is neither Free nor a subscriber, and
    /// showing them "Premium" with a mini-course allowance they do not have
    /// would be the undisclosed-cap problem again, one tier along.
    private var planSection: some View {
        section("Plan") {
            HStack {
                Text(Self.planName(for: entitlements.snapshot.tier))
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                Spacer()
                if let trailing = planTrailing {
                    Text(trailing)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .accessibilityIdentifier("settings.plan")

            Text(planDetail)
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    entitlements.isTrialing
                        ? "settings.trialAllowance"
                        : "settings.miniCourseAllowance"
                )
        }
    }

    /// `nonisolated` because it is a pure function of a tier and nothing
    /// else. Without it, `SettingsView`'s inferred main-actor isolation comes
    /// with it, and passing the method as a function value -- which the copy
    /// tests do -- is a Swift 6 error about losing a global actor.
    nonisolated static func planName(for tier: Tier) -> String {
        switch tier {
        case .free: "Free"
        case .trialing: "Premium trial"
        case .monthly, .yearly: "Premium"
        }
    }

    /// The short right-hand summary. Nil for a subscriber: the detail line
    /// below already carries their one allowance, and repeating it in two
    /// sizes on one row reads as two different limits.
    private var planTrailing: String? {
        if entitlements.isTrialing {
            let days = entitlements.trialDaysRemaining()
            return "\(days) \(days == 1 ? "day" : "days") left"
        }
        return entitlements.hasPremiumAccess ? nil : "1 lesson a day"
    }

    private var planDetail: String {
        Self.planDetail(
            tier: entitlements.snapshot.tier,
            trial: entitlements.snapshot.trial,
            miniCoursesRemaining: entitlements.miniCoursesRemaining
        )
    }

    /// The disclosure. Built from the limits rather than written out, and
    /// static so `TrialCopyTests` can read it without a view — the same shape
    /// as `PaywallView.freeTierDisclosure`, and for the same reason: this is
    /// a promise, and the trial's cap has to be visible while there is still
    /// some of it left to spend.
    nonisolated static func planDetail(tier: Tier, trial: TrialMirror, miniCoursesRemaining: Int) -> String {
        switch tier {
        case .trialing:
            return "\(trial.remainingLessons) of \(TrialLimits.lessons) trial lessons left, "
                + "including \(trial.remainingCourses) of \(TrialLimits.courses) mini-courses. "
                + "No card, nothing to cancel."
        case .monthly, .yearly:
            return "\(miniCoursesRemaining) of \(EntitlementRules.premiumMiniCoursesPerMonth) "
                + "mini-courses left this month. Shorter lessons are unlimited."
        case .free:
            return "Free covers the 3- and 7-minute lengths, one lesson a day, and your whole "
                + "library. Nothing you have learned is ever hidden or deleted."
        }
    }

    private var apiKeyStatusText: String {
        if hasStoredKey {
            return "A key is stored on this device. Lessons are generated live."
        }
        return entitlements.hasPremiumAccess
            ? "No developer key stored. Premium lessons are generated normally."
            : "No key stored. The app runs on built-in sample lessons."
    }

    // MARK: - API key

    private var apiKeySection: some View {
        section("Anthropic API key") {
            // Was shown unconditionally, including to Premium subscribers,
            // so a paying user was told the app "runs on built-in sample
            // lessons" — which reads as the thing they paid for not working.
            Text(apiKeyStatusText)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)

            SecureField("sk-ant-…", text: $keyEntry)
                .textFieldStyle(.plain)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.ControlSize.textField)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
                )
                .accessibilityIdentifier("settings.apiKeyField")

            HStack(spacing: Theme.Spacing.xs) {
                Button(action: saveKey) {
                    // Disabled state is a border, not a dimmed fill: an accent
                    // fill at reduced opacity turned muddy in dark mode, where
                    // the accent already sits close to the background in
                    // luminance. A border reads as "inactive" without mixing
                    // two low-contrast colors together.
                    Text("Save key")
                        .font(Theme.Font.headline.font)
                        .foregroundStyle(keyEntry.isEmpty ? palette.secondaryText : palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.ControlSize.button)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                .fill(keyEntry.isEmpty ? Color.clear : palette.accent)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                .strokeBorder(
                                    keyEntry.isEmpty ? palette.borderInteractive : Color.clear,
                                    lineWidth: Theme.borderWidth
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(keyEntry.isEmpty)
                .accessibilityIdentifier("settings.saveKey")

                if hasStoredKey {
                    Button(action: clearKey) {
                        Text("Clear")
                            .font(Theme.Font.headline.font)
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Theme.ControlSize.button)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                    .strokeBorder(palette.borderInteractive, lineWidth: Theme.borderWidth)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.clearKey")
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    // MARK: - Reading

    private var readingSection: some View {
        section("Reading") {
            labelledPicker("Appearance") {
                ThemedSegmentedControl(
                    options: Theme.AppearanceMode.allCases,
                    label: \.label,
                    selection: Binding(
                        get: { Theme.AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
                        set: { appearanceModeRaw = $0.rawValue }
                    )
                )
                .accessibilityIdentifier("settings.appearance")
            }

            labelledPicker("Text size") {
                ThemedSegmentedControl(
                    options: TextSizeStep.allCases,
                    label: \.label,
                    selection: Binding(
                        get: { TextSizeStep(rawValue: textSizeStepRaw) ?? .standard },
                        set: { textSizeStepRaw = $0.rawValue }
                    )
                )
                .accessibilityIdentifier("settings.textSize")
            }
        }
    }

    // MARK: - Reminder

    private var reminderSection: some View {
        section("Recall reminder") {
            Text("One nudge a day, at most, and only when a question is actually due.")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)

            DatePicker("Reminder time", selection: recallTimeBinding, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(palette.accent)
                .accessibilityIdentifier("settings.recallTime")

            #if DEBUG
            // The first recall interval is a day, and the reminder fires at a
            // time of the reader's choosing — so "do notifications work?"
            // cannot otherwise be answered without waiting until tomorrow.
            // That is a fine property for the product and a useless one for
            // somebody with a borrowed Mac for an afternoon.
            //
            // DEBUG only: it cannot reach a release build.
            Button("Send a test reminder in 10 seconds") {
                NotificationScheduler.sendTestNotification()
            }
            .font(Theme.Font.label.font)
            .foregroundStyle(palette.accent)
            .accessibilityIdentifier("settings.testNotification")
            #endif
        }
    }

    // MARK: - Widget

    /// Whether the widget can actually see the library.
    ///
    /// `AppGroup.isSharedStorageAvailable` has always existed and its own
    /// documentation said it was "surfaced in Settings rather than left as a
    /// silent condition". It was not. Without it, a widget showing zero is
    /// indistinguishable from a reader who has finished nothing — and the two
    /// have completely different causes, one of which is an entitlement that
    /// a free personal development team cannot grant at all.
    private var widgetSection: some View {
        section("Widget") {
            HStack(alignment: .firstTextBaseline) {
                Text("Shared storage")
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.text)
                Spacer()
                Text(AppGroup.isSharedStorageAvailable ? "Available" : "Unavailable")
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier("settings.sharedStorage")
            }

            Text(AppGroup.isSharedStorageAvailable
                 ? "The widget reads the same library this app does."
                 : "The widget cannot read your library, so it will show nothing. "
                   + "This build's App Group entitlement is not in effect.")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
        }
    }

    // MARK: - Usage

    private var usageSection: some View {
        section("Usage") {
            HStack {
                Text("This month")
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.text)
                Spacer()
                Text(CostEstimator.formatted(monthTotal))
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                    .accessibilityIdentifier("settings.monthlyTotal")
            }

            HStack {
                Text("All time")
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text(CostEstimator.formatted(allTimeTotal))
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
            }

            Text("Estimated from token counts returned by the API, across \(usageEvents.count) call\(usageEvents.count == 1 ? "" : "s"). Your actual bill is the one Anthropic sends.")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
        }
    }

    // MARK: - About

    #if DEBUG
    private var funnelDebugSection: some View {
        section("Instrumentation") {
            NavigationLink {
                FunnelDebugView()
            } label: {
                HStack {
                    Text("Trial funnel")
                        .font(Theme.Font.body.font)
                        .foregroundStyle(palette.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Theme.Font.caption.font)
                        .foregroundStyle(palette.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.funnelDebug")
        }
    }
    #endif

    private var aboutSection: some View {
        section("About the key") {
            Text("The key is stored in this device's Keychain and sent straight to Anthropic. It never goes to any server of ours, because there isn't one.")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
            Text("A key held on a device can be extracted by someone with that device. Use a key scoped to this app, and revoke it if you lose the phone.")
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
        }
    }

    // MARK: - Building blocks

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title.uppercased())
                .font(Theme.Font.caption.font)
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelledPicker(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.text)
            content()
        }
    }

    // MARK: - Actions

    private func saveKey() {
        do {
            try keyStore.save(keyEntry)
            keyEntry = ""
            hasStoredKey = true
            statusMessage = "Key saved to the Keychain."
        } catch {
            statusMessage = "Couldn't save the key to the Keychain."
        }
    }

    private func clearKey() {
        do {
            try keyStore.delete()
            hasStoredKey = false
            statusMessage = "Key removed. Back to sample lessons."
        } catch {
            statusMessage = "Couldn't remove the key."
        }
    }
}
