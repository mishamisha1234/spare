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
                usageSection
                aboutSection
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

    /// States the plan and, for premium, the mini-course allowance — before
    /// it bites rather than at the moment it does. A cap discovered only on
    /// refusal is a worse deal than the same cap stated up front.
    private var planSection: some View {
        section("Plan") {
            HStack {
                Text(entitlements.isPremium ? "Premium" : "Free")
                    .font(Theme.Font.headline.font)
                    .foregroundStyle(palette.text)
                Spacer()
                if !entitlements.isPremium {
                    Text("1 lesson a day")
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .accessibilityIdentifier("settings.plan")

            if entitlements.isPremium {
                Text("\(entitlements.miniCoursesRemaining) of \(EntitlementRules.premiumMiniCoursesPerMonth) mini-courses left this month. Shorter lessons are unlimited.")
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.miniCourseAllowance")
            } else {
                Text("Free covers the 3- and 10-minute lengths, one lesson a day, and your last \(EntitlementRules.freeLibraryLimit) library entries.")
                    .font(Theme.Font.caption.font)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apiKeyStatusText: String {
        if hasStoredKey {
            return "A key is stored on this device. Lessons are generated live."
        }
        return entitlements.isPremium
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
