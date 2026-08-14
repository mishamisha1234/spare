import SwiftUI
import SwiftData
import SpareCore

@main
struct SpareApp: App {
    /// `-UITEST_RESET_STATE` (set by the screenshot UI test) forces an
    /// in-memory store and clears onboarding/appearance defaults, so every
    /// test run starts from the same clean slate regardless of what a
    /// previous run left on the simulator.
    private static var isUITestReset: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITEST_RESET_STATE")
    }

    private let container: ModelContainer = PersistenceStack.makeContainer(inMemory: isUITestReset)

    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = Theme.AppearanceMode.system.rawValue

    init() {
        if Self.isUITestReset {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: AppSettingsKey.hasCompletedOnboarding)
            defaults.removeObject(forKey: AppSettingsKey.appearanceMode)
            defaults.removeObject(forKey: AppSettingsKey.textSizeStep)
        }
    }

    /// `-UITEST_COLOR_SCHEME` (light/dark) forces the appearance for
    /// screenshot determinism, overriding both the stored preference and the
    /// simulator's actual system setting.
    private var appearanceMode: Theme.AppearanceMode {
        if let forced = ProcessInfo.processInfo.environment["UITEST_COLOR_SCHEME"],
           let mode = Theme.AppearanceMode(rawValue: forced) {
            return mode
        }
        return Theme.AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .themedAppearance(appearanceMode)
                // The one line that changes when AnthropicDirectProvider
                // (Phase 3) replaces MockProvider.
                .environment(\.lessonProvider, MockProvider())
        }
        .modelContainer(container)
    }
}
