import SwiftUI
import SwiftData
import SpareCore

@main
struct SpareApp: App {
    private let container = PersistenceStack.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
