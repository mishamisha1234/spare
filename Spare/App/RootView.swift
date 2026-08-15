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
    @State private var path: [AppRoute] = []

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                NavigationStack(path: $path) {
                    HomeView(
                        onSelect: { window in path.append(.suggestions(window)) },
                        onViewRecallLesson: { lessonID in path.append(.lessonDetail(lessonID)) }
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
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    path.append(.library)
                                } label: {
                                    Image(systemName: "books.vertical")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("home.libraryButton")
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
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .suggestions(let window):
            SuggestionsView(
                window: window, provider: provider, modelContext: modelContext
            ) { suggestion in
                path.append(.reader(.newTopic(suggestion, window: window)))
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
                onTakeTest: { path.append(.postLessonTest(lessonID: lessonID)) }
            )

        case .library:
            LibraryView(
                onSelect: { lesson in path.append(.lessonDetail(lesson.id)) },
                onOpenStats: { path.append(.stats) }
            )

        case .lessonDetail(let lessonID):
            if let lesson = modelContext.storedLesson(id: lessonID) {
                LessonDetailView(lesson: lesson)
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

#Preview {
    RootView()
        .modelContainer(PersistenceStack.makeContainer(inMemory: true))
}
