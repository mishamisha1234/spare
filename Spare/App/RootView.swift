import SwiftUI
import SwiftData
import SpareCore

/// Owns the navigation stack for the whole app. Onboarding gates everything
/// else; once it's done, Home is the permanent root and every other screen is
/// a push.
struct RootView: View {
    @AppStorage(AppSettingsKey.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.lessonProvider) private var provider
    @Environment(\.attachmentStore) private var attachmentStore
    @Environment(\.pointsLedger) private var pointsLedger
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var entitlements: EntitlementService
    @AppStorage(AppSettingsKey.hasShownFirstLessonPaywall) private var hasShownFirstLessonPaywall = false
    @AppStorage(AppSettingsKey.hasOfferedTrial) private var hasOfferedTrial = false
    @AppStorage(AppSettingsKey.hasShownTrialSummary) private var hasShownTrialSummary = false

    /// Whether anything has ever been finished. The ordering rule turns on
    /// this and nothing else: the paywall never appears before the first
    /// complete lesson, so the question is not "how long since install" or
    /// "how many launches" but "have they seen the product work".
    @Query(filter: #Predicate<StoredLesson> { $0.completedAt != nil })
    private var completedLessons: [StoredLesson]
    @Query private var recallItems: [StoredRecallItem]

    @State private var path: [AppRoute] = []
    /// One sheet slot, not three.
    ///
    /// Two `.sheet` modifiers on the same view do not reliably both work, and
    /// this flow deliberately chains them -- the paywall's dismissal is what
    /// presents the trial offer, and the day-7 summary's primary button is
    /// what presents the paywall. One item with a `pendingSheet` queue makes
    /// that sequencing explicit instead of a race.
    @State private var sheet: RootSheet?
    @State private var pendingSheet: RootSheet?
    @State private var capTitle = ""
    @State private var capMessage: String?

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                NavigationStack(path: $path) {
                    HomeView(
                        onSelect: startLesson(in:),
                        onViewRecallLesson: { lessonID in path.append(.lessonDetail(lessonID)) },
                        onResumeCourse: { lessonID, chapterIndex in
                            path.append(.resumeCourse(lessonID: lessonID, chapterIndex: chapterIndex))
                        }
                    )
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    path.append(.settings)
                                } label: {
                                    Image(systemName: "gearshape")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.settingsButton")
                                // Without this VoiceOver reads the SF Symbol
                                // name — confirmed in a CI tree dump, which
                                // showed label: 'gearshape'.
                                .accessibilityLabel("Settings")
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    path.append(.library)
                                } label: {
                                    Image(systemName: "books.vertical")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.libraryButton")
                                .accessibilityLabel("Library")
                            }
                        }
                        .navigationDestination(for: AppRoute.self) { route in
                            destination(for: route)
                        }
                        // The declarative half of the toolbar-chrome fix; the
                        // UIKit appearance proxy in NavigationBarChrome is the
                        // other half. Applied to the stack's root so it covers
                        // every pushed screen.
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
            } else {
                OnboardingView(onFinished: { hasCompletedOnboarding = true })
            }
        }
        // Recomputed on every return to the foreground, not just when recall
        // state actually changes — cheap, and it's the backstop that catches
        // a due date drifting into "now" purely from time passing while the
        // app was backgrounded.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasCompletedOnboarding else { return }
            NotificationScheduler.reschedule(modelContext: modelContext)
        }
        .task {
            guard hasCompletedOnboarding else { return }
            NotificationScheduler.reschedule(modelContext: modelContext)
        }
        .task { entitlements.start() }
        .onOpenURL { url in
            guard hasCompletedOnboarding, let link = WidgetDeepLink(url: url) else { return }
            open(link)
        }
        .sheet(item: $sheet, onDismiss: presentPendingSheet) { presentation in
            switch presentation {
            case .paywall(let trigger):
                PaywallView(trigger: trigger)
                    .entitlementService(entitlements)
                    // Sized to the content: at .large there was ~300pt of empty
                    // sheet under the fine print.
                    .presentationDetents([.height(720), .large])

            case .trialOffer:
                TrialOfferView()
                    .presentationDetents([.height(360), .large])

            case .trialSummary(let summary):
                TrialSummaryView(summary: summary) {
                    // Queued rather than swapped: replacing a live sheet's
                    // item mid-presentation animates badly and can drop the
                    // second one entirely.
                    pendingSheet = .paywall(.trialEnded)
                    sheet = nil
                }
                .presentationDetents([.height(420), .large])
            }
        }
        .alert(
            capTitle,
            isPresented: Binding(get: { capMessage != nil }, set: { if !$0 { capMessage = nil } })
        ) {
            Button("OK", role: .cancel) { capMessage = nil }
        } message: {
            Text(capMessage ?? "")
        }
        // An install that already has finished lessons predates the day-0
        // ask, and springing a paywall on them at launch would be an ambush
        // rather than an offer. Marked as already shown, silently.
        .task {
            if !completedLessons.isEmpty { hasShownFirstLessonPaywall = true }
            presentTrialSummaryIfNeeded()
        }
        // The moment the product has demonstrated itself once. This is the
        // only place the day-0 paywall is raised, and it cannot fire earlier
        // because it is driven by the transition out of zero.
        .onChange(of: completedLessons.count) { previous, count in
            guard previous == 0, count > 0 else { return }
            presentFirstLessonPaywall()
        }
        .onChange(of: entitlements.hasTrialEnded) { _, ended in
            if ended { presentTrialSummaryIfNeeded() }
        }
    }

    // MARK: - The trial's three moments

    /// The day-0 ask, once, immediately after the first complete lesson.
    private func presentFirstLessonPaywall() {
        guard !hasShownFirstLessonPaywall, !entitlements.hasPremiumAccess else { return }
        hasShownFirstLessonPaywall = true
        presentPaywall(.firstLessonComplete)
    }

    /// Every paywall goes through here, so the free week is offered from one
    /// place.
    ///
    /// The spec describes the offer following the day-0 paywall specifically.
    /// It follows *any* dismissed paywall while the device is still eligible,
    /// which is a deliberate widening: withholding an unclaimed free week
    /// because the paywall happened to come from a different tap would be
    /// arbitrary, and the reader has just declined to pay either way.
    /// `hasOfferedTrial` bounds it to once, so it cannot become a nag.
    ///
    /// Queued when the paywall opens rather than decided when it closes, so
    /// the decision is made once from one state instead of from whatever the
    /// entitlement looks like a beat after a purchase lands.
    private func presentPaywall(_ trigger: PaywallTrigger) {
        if entitlements.isTrialEligible, !hasOfferedTrial {
            pendingSheet = .trialOffer
        }
        sheet = .paywall(trigger)
    }

    /// Runs after any sheet closes.
    private func presentPendingSheet() {
        guard let next = pendingSheet else { return }
        pendingSheet = nil

        guard case .trialOffer = next else {
            sheet = next
            return
        }
        // Somebody who bought does not need a free week offered to them, and
        // the server would refuse to start one anyway.
        guard !entitlements.hasPremiumAccess else { return }
        Task { await startAndAnnounceTrial() }
    }

    /// Claims the week, then announces it.
    ///
    /// In that order, and only announcing if it worked. The sheet says "here's
    /// Spare Premium free for 7 days"; showing that after a failed claim would
    /// promise something the server has not granted, and the reader would find
    /// locked circles behind it. A failure leaves `hasOfferedTrial` false, so
    /// the next paywall dismissal tries again.
    private func startAndAnnounceTrial() async {
        guard await entitlements.startTrial().started else { return }
        hasOfferedTrial = true
        sheet = .trialOffer
    }

    /// The day-7 collapse, on the first open after expiry.
    private func presentTrialSummaryIfNeeded() {
        guard entitlements.hasTrialEnded,
              !hasShownTrialSummary,
              !entitlements.hasPremiumAccess,
              sheet == nil
        else { return }
        hasShownTrialSummary = true
        sheet = .trialSummary(trialSummary())
    }

    /// The reader's own numbers. Counted from the trial's start where there is
    /// one, so "things you now know" means the week rather than all time.
    private func trialSummary() -> TrialSummary {
        TrialSummaryBuilder.make(
            completionDates: completedLessons.compactMap(\.completedAt),
            recallResults: recallItems.map(\.lastResult),
            since: entitlements.snapshot.trial.startedAt,
            now: .now
        )
    }

    /// Handles a widget tap.
    ///
    /// The destination is re-checked against the live entitlement rather than
    /// trusted: the widget's timeline can be an hour stale, so a length it
    /// rendered as open may have locked since (or the reverse). The widget
    /// picks the likely destination; this decides the real one.
    private func open(_ link: WidgetDeepLink) {
        path.removeAll()
        switch link {
        case .suggestions(let window):
            startLesson(in: window)
        case .paywall(let window):
            // Still routed through the gate: if they bought Premium since the
            // widget last refreshed, send them to the lesson they wanted
            // rather than a paywall for something they already own.
            startLesson(in: window)
        case .resumeCourse(let lessonID, let chapterIndex):
            guard modelContext.storedLesson(id: lessonID) != nil else { return }
            path.append(.resumeCourse(lessonID: lessonID, chapterIndex: chapterIndex))
        }
    }

    /// The gate for picking a duration on Home.
    ///
    /// A denial with a trigger opens the paywall; a `.capped` decision (a
    /// paying user at the mini-course limit) surfaces the limit instead,
    /// since selling them something they already own would be absurd. The
    /// circles themselves carry no lock badge: on Home, size is the only
    /// thing allowed to mean anything, and lock icons on two of four would
    /// wreck that. The lock is stated on the paywall the tap opens.
    /// What a reader with nothing finished is told when they tap a locked
    /// length.
    ///
    /// Deliberately not the paywall, and deliberately not silence either --
    /// a tap that does nothing reads as broken. It states the two lengths
    /// that are open and names the one that isn't, and asks for nothing.
    static let preFirstLessonNote =
        "Start with 3 or 7 minutes. The other lengths are part of Premium."

    private func startLesson(in window: TimeWindow) {
        let decision = entitlements.canStartLesson(window: window)
        switch decision {
        case .allowed:
            path.append(.suggestions(window))
        case .denied(let trigger):
            // The ordering rule, and the only place it is enforced.
            //
            // A reader who has finished nothing has not been shown that this
            // works, and a price is not the answer to their first tap. They
            // get a note instead: no price, no plan rows, no button. It names
            // Premium, which is the point -- the word arrives without anything
            // being asked of them, which is exactly what the rule is for.
            guard !completedLessons.isEmpty else {
                capTitle = "Two lengths to start with"
                capMessage = Self.preFirstLessonNote
                return
            }
            presentPaywall(trigger)
        case .capped(.miniCoursesThisMonth(_, let cap)):
            capTitle = "Mini-course limit reached"
            capMessage = "You've started all \(cap) mini-courses included this month. The count resets on the 1st — shorter lessons are unaffected."
        case .capped(.trialCoursesThisWeek(_, let cap)):
            // A note, not the paywall. They still have most of a free week,
            // and selling to somebody in the middle of a gift is the shakedown
            // the ordering rule exists to prevent.
            capTitle = "That's both mini-courses"
            capMessage = "That's both \(cap == 1 ? "course" : "courses") from your free week. Every other length still works."
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .suggestions(let window):
            SuggestionsView(
                window: window, provider: provider, modelContext: modelContext
            ) { suggestion in
                // Committing to a topic is what spends the free daily
                // allowance — browsing suggestions doesn't.
                entitlements.recordLessonStarted(window: window)
                path.append(.reader(.newTopic(suggestion, window: window)))
            } onOpenSettings: {
                path.append(.settings)
            }

        case .reader(let source):
            ReaderView(source: source, provider: provider, modelContext: modelContext) { lessonID in
                path.append(.completion(lessonID: lessonID))
            }

        case .completion(let lessonID):
            CompletionView(
                lessonID: lessonID,
                provider: provider,
                modelContext: modelContext,
                attachments: attachmentStore,
                onGoDeeper: { angle in
                    guard let lesson = modelContext.storedLesson(id: lessonID) else { return }
                    path.append(.reader(.goDeeper(parentLessonID: lessonID, angle: angle, window: lesson.window)))
                },
                onReturnHome: { path.removeAll() },
                onTakeTest: { path.append(.postLessonTest(lessonID: lessonID)) },
                onPaywall: { trigger in paywall = PaywallPresentation(trigger: trigger) }
            )

        case .library:
            LibraryView(
                onSelect: { lesson in path.append(.lessonDetail(lesson.id)) },
                onOpenStats: { path.append(.stats) },
                onPickLength: { path.removeAll() }
            )

        case .lessonDetail(let lessonID):
            if let lesson = modelContext.storedLesson(id: lessonID) {
                LessonDetailView(lesson: lesson)
            }

        case .resumeCourse(let lessonID, let chapterIndex):
            if let lesson = modelContext.storedLesson(id: lessonID) {
                LessonDetailView(lesson: lesson, resumeChapterIndex: chapterIndex)
            }

        case .settings:
            SettingsView()

        case .postLessonTest(let lessonID):
            PostLessonTestView(
                lessonID: lessonID,
                modelContext: modelContext,
                pointsLedger: pointsLedger,
                onFinished: { path.removeLast() }
            )

        case .stats:
            StatsView()
        }
    }
}

/// `.sheet(item:)` needs an `Identifiable`, and `PaywallTrigger` is a plain
/// value type in SpareCore that shouldn't take on a UI-framework conformance
/// just to be presented.
/// Everything the root can put in front of the reader, as one value.
///
/// See the `sheet` property for why there is one slot rather than three.
private enum RootSheet: Identifiable {
    case paywall(PaywallTrigger)
    case trialOffer
    case trialSummary(TrialSummary)

    var id: String {
        switch self {
        case .paywall(let trigger): "paywall-\(trigger)"
        case .trialOffer: "trialOffer"
        case .trialSummary: "trialSummary"
        }
    }
}

#Preview {
    let container = PersistenceStack.makeContainer(inMemory: true)
    return RootView()
        .modelContainer(container)
        .entitlementService(EntitlementService(store: StubPurchaseStore(), container: container))
}
