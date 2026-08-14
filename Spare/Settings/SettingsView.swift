import SwiftUI
import SwiftData
import SpareCore

/// API key entry, reading preferences, and what the key has cost this month.
struct SettingsView: View {

    @Query(sort: \StoredUsageEvent.occurredAt, order: .reverse)
    private var usageEvents: [StoredUsageEvent]

    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = Theme.AppearanceMode.system.rawValue
    @AppStorage(AppSettingsKey.textSizeStep) private var textSizeStepRaw = TextSizeStep.standard.rawValue

    @Environment(\.colorScheme) private var colorScheme
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                apiKeySection
                readingSection
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

    // MARK: - API key

    private var apiKeySection: some View {
        section("Anthropic API key") {
            Text(hasStoredKey
                 ? "A key is stored on this device. Lessons are generated live."
                 : "No key stored. The app runs on built-in sample lessons.")
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)

            SecureField("sk-ant-…", text: $keyEntry)
                .textFieldStyle(.plain)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, Theme.Spacing.s)
                .frame(height: Theme.ControlSize.textField)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                )
                .accessibilityIdentifier("settings.apiKeyField")

            HStack(spacing: Theme.Spacing.xs) {
                Button(action: saveKey) {
                    Text("Save key")
                        .font(Theme.Font.headline.font)
                        .foregroundStyle(palette.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.ControlSize.button)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                .fill(palette.accent)
                                .opacity(keyEntry.isEmpty ? Theme.Interaction.disabledOpacity : 1)
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
                            .frame(height: Theme.ControlSize.button)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                    .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
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
                Picker("Appearance", selection: $appearanceModeRaw) {
                    ForEach(Theme.AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
            }

            labelledPicker("Text size") {
                Picker("Text size", selection: $textSizeStepRaw) {
                    ForEach(TextSizeStep.allCases) { step in
                        Text(step.label).tag(step.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.textSize")
            }
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
