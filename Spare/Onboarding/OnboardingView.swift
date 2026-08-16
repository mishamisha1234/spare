import SwiftUI
import SwiftData
import SpareCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Five steps, skippable from step 3 onward. No account, ever.
struct OnboardingView: View {
    var onFinished: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @State private var step: Step = .pitch
    @State private var interests: Set<String> = []
    @State private var customInterest: String = ""
    @State private var work: String = ""
    @State private var curiosityGaps: [String] = []
    @State private var currentGapEntry: String = ""

    private var palette: Theme.Palette { Theme.palette(for: colorScheme) }

    enum Step: Int, CaseIterable {
        case pitch, interests, work, curiosityGaps, notifications

        /// Steps 1 and 2 are mandatory; from step 3 onward the user can skip.
        var isSkippable: Bool { rawValue >= 2 }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, Theme.Spacing.m)

            Spacer(minLength: Theme.Spacing.m)

            Group {
                switch step {
                case .pitch: pitchStep
                case .interests: interestsStep
                case .work: workStep
                case .curiosityGaps: curiosityGapsStep
                case .notifications: notificationsStep
                }
            }
            .themedAppear()
            .id(step) // re-triggers the appear animation per step

            Spacer(minLength: Theme.Spacing.m)

            footer
                .padding(.bottom, Theme.Spacing.l)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        // No container-level accessibilityIdentifier here: SwiftUI propagates
        // an identifier set on a container down to every descendant element
        // that doesn't get a more specific one applied to it afterwards --
        // this exact line was clobbering onboarding.primary, every chip, and
        // both text fields with "onboarding.step.N", confirmed by dumping
        // app.debugDescription in CI (every element on the pitch screen
        // shared one identifier). Each step's controls already carry their
        // own meaningful identifiers; nothing needs one at this level too.
    }

    // MARK: - Steps

    private var pitchStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Tell us how long you have.")
                .font(Theme.Font.largeTitle.font)
                .foregroundStyle(palette.text)
            Text("We'll find something worth learning.")
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interestsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            stepHeader("What are you drawn to?", subtitle: "Pick as many as you like.")

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 108), spacing: Theme.Spacing.xs)],
                    spacing: Theme.Spacing.xs
                ) {
                    ForEach(OnboardingDomains.all, id: \.self) { domain in
                        chip(domain, isSelected: interests.contains(domain)) {
                            toggle(domain)
                        }
                    }
                }
            }

            HStack(spacing: Theme.Spacing.xs) {
                TextField("Something else…", text: $customInterest)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minHeight: Theme.ControlSize.textField)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                    )
                    .onSubmit(addCustomInterest)
                    .accessibilityIdentifier("onboarding.customInterest")

                if !customInterest.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: addCustomInterest)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("onboarding.addCustomInterest")
                }
            }
        }
    }

    private var workStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            stepHeader("What do you do?", subtitle: "Helps us pick examples that land.")
            TextField("e.g. physiotherapist, teacher, product manager", text: $work)
                .textFieldStyle(.plain)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.text)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.ControlSize.textField)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                )
                .accessibilityIdentifier("onboarding.work")
        }
    }

    private var curiosityGapsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            stepHeader(
                "What do you nod along to but not actually understand?",
                subtitle: "No wrong answers here — this is the fun part."
            )

            HStack(spacing: Theme.Spacing.xs) {
                TextField("e.g. how interest rates work", text: $currentGapEntry)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minHeight: Theme.ControlSize.textField)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                    )
                    .onSubmit(addCuriosityGap)
                    .accessibilityIdentifier("onboarding.curiosityGapEntry")

                if !currentGapEntry.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add", action: addCuriosityGap)
                        .font(Theme.Font.label.font)
                        .foregroundStyle(palette.accent)
                        .accessibilityIdentifier("onboarding.addCuriosityGap")
                }
            }

            if !curiosityGaps.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(curiosityGaps, id: \.self) { gap in
                        HStack {
                            Text(gap)
                                .font(Theme.Font.label.font)
                                .foregroundStyle(palette.text)
                            Spacer()
                            Button {
                                curiosityGaps.removeAll { $0 == gap }
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.s)
                        .frame(minHeight: Theme.ControlSize.chip)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                .strokeBorder(palette.border, lineWidth: Theme.borderWidth)
                        )
                    }
                }
            }
        }
    }

    private var notificationsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            stepHeader(
                "One nudge a day, at most.",
                subtitle: "We'll only remind you when a recall question is ready — never to reopen the app."
            )
        }
    }

    // MARK: - Shared pieces

    private func stepHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Font.title.font)
                .foregroundStyle(palette.text)
            Text(subtitle)
                .font(Theme.Font.label.font)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func chip(_ text: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.Font.label.font)
                .lineLimit(1)
                .minimumScaleFactor(Theme.Interaction.chipLabelMinimumScale)
                .foregroundStyle(isSelected ? palette.textOnAccent : palette.text)
                .padding(.horizontal, Theme.Spacing.s)
                .frame(minHeight: Theme.ControlSize.chip)
                .background(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .fill(isSelected ? palette.accent : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(isSelected ? Color.clear : palette.border, lineWidth: Theme.borderWidth)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding.chip.\(text)")
    }

    private var progressDots: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(Step.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate == step ? palette.accent : palette.border)
                    .frame(width: Theme.ControlSize.progressDot, height: Theme.ControlSize.progressDot)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button(action: primaryAction) {
                Text(primaryLabel)
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
            .accessibilityIdentifier("onboarding.primary")

            if step.isSkippable {
                Button("Skip", action: advance)
                    .font(Theme.Font.label.font)
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }

    private var primaryLabel: String {
        switch step {
        case .pitch: "Get started"
        case .notifications: "Turn on reminders"
        default: "Continue"
        }
    }

    // MARK: - Actions

    private func toggle(_ domain: String) {
        if interests.contains(domain) {
            interests.remove(domain)
        } else {
            interests.insert(domain)
        }
    }

    private func addCustomInterest() {
        let trimmed = customInterest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        interests.insert(trimmed)
        customInterest = ""
    }

    private func addCuriosityGap() {
        let trimmed = currentGapEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        curiosityGaps.append(trimmed)
        currentGapEntry = ""
    }

    private func primaryAction() {
        if step == .notifications {
            requestNotificationPermission()
        }
        advance()
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = next
    }

    /// Records the intent only.
    ///
    /// Requesting here fired the system prompt asynchronously, so it landed
    /// on Home a moment after onboarding finished — asking for a permission
    /// whose payoff ("one question a day about what you read") the reader
    /// cannot experience for at least a day, at the exact moment they are
    /// trying to start their first lesson. The prompt now waits until a
    /// recall question is genuinely due, when the ask makes sense on its own.
    private func requestNotificationPermission() {
        UserDefaults.standard.set(true, forKey: AppSettingsKey.wantsRecallReminders)
    }

    private func finish() {
        let snapshot = ProfileSnapshot(
            interests: Array(interests),
            work: work.trimmingCharacters(in: .whitespacesAndNewlines),
            curiosityGaps: curiosityGaps,
            complexity: .standard
        )
        modelContext.insert(StoredProfile(snapshot: snapshot))
        try? modelContext.save()
        onFinished()
    }
}

#Preview {
    OnboardingView(onFinished: {})
        .modelContainer(PersistenceStack.makeContainer(inMemory: true))
}
