import Foundation
import SwiftData

/// Owns the app's SwiftData stack, in one place, so the schema is declared once
/// and store creation is not left to defaults.
enum PersistenceStack {

    static func makeSchema() -> Schema {
        Schema([
            StoredProfile.self,
            StoredLesson.self,
            StoredRecallItem.self,
            StoredSuggestionCache.self,
            StoredEntitlement.self,
            StoredUsageEvent.self,
        ])
    }

    /// The on-disk store location.
    ///
    /// `Application Support` is not present in a freshly created app container,
    /// and SwiftData's default store path does not create it — the store then
    /// fails to open with ENOENT. Creating the directory first is the fix.
    static func storeURL() -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Spare.store")
    }

    /// The app's container. Falls back to an in-memory store rather than
    /// refusing to launch: a reader with a broken store should still be able to
    /// open the app and read something.
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = makeSchema()

        if !inMemory {
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(url: storeURL())
                )
            } catch {
                #if DEBUG
                print("[Spare] on-disk store unavailable (\(error)); using in-memory")
                #endif
            }
        }

        do {
            return try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            fatalError("SwiftData could not create even an in-memory container: \(error)")
        }
    }
}
