import SwiftUI
import SwiftData
import SpareCore

@main
struct SpareApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [
            StoredProfile.self,
            StoredLesson.self,
            StoredRecallItem.self,
            StoredSuggestionCache.self,
            StoredEntitlement.self,
        ])
    }
}
