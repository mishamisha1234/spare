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
    @Environment(\.pointsLedger) private var pointsLedger
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var entitlements: EntitlementService
    @State private var path: [AppRoute] = []
    @State private var paywall: PaywallPresentation?
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
        .sheet(item: $paywall) { presentation in
            PaywallView(trigger: presentation.trigger)
                .entitlementService(entitlements)
                // Sized to the content: at .large there was ~300pt of empty
                // sheet under the fine print.
                .presentationDetents([.height(720), .large])
        }
        .alert(
            "Mini-course limit reached",
            isPresented: Binding(get: { capMessage != nil }, set: { if !$0 { capMessage = nil } })
        ) {
            Button("OK", role: .cancel) { capMessage = nil }
        } message: {
            Text(capMessage ?? "")
        }
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
    private func startLesson(in window: TimeWindow) {
        let decision = entitlements.canStartLesson(window: window)
        switch decision {
        case .allowed:
            path.append(.suggestions(window))
        case .denied(let trigger):
            paywall = PaywallPresentation(trigger: trigger)
        case .capped(.miniCoursesThisMonth(_, let cap)):
            capMessage = "You've started all \(cap) mini-courses included this month. The count resets on the 1st — shorter lessons are unaffected."
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
                provider: provider,
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
private struct PaywallPresentation: Identifiable {
    let trigger: PaywallTrigger
    var id: String { String(describing: trigger) }
}

#Preview {
    let container = PersistenceStack.makeContainer(inMemory: true)
    return RootView()
        .modelContainer(container)
        .entitlementService(EntitlementService(store: StubPurchaseStore(), container: container))
}
