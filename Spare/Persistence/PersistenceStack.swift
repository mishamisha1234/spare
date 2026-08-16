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
            StoredPointEvent.self,
        ])
    }

    /// The on-disk store location.
    ///
    /// Prefers the App Group container, because the widget extension is a
    /// separate process and can only read the library if the store lives
    /// somewhere both can reach.
    ///
    /// Falls back to the app's own container when the group isn't available
    /// — which is a real case, not paranoia: unsigned builds don't get the
    /// entitlement applied, so CI runs here. The app must keep working, with
    /// the widget simply showing nothing.
    ///
    /// `Application Support` is not present in a freshly created app container,
    /// and SwiftData's default store path does not create it — the store then
    /// fails to open with ENOENT. Creating the directory first is the fix.
    static func storeURL() -> URL {
        if let shared = AppGroup.sharedStoreURL() {
            return shared
        }
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "Spare.store")
    }

    /// The store the app used before the App Group existed. Kept so a build
    /// that gains the entitlement can move existing data across instead of
    /// appearing to have lost the whole library.
    static func legacyStoreURL() -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appending(path: "Spare.store")
    }

    /// Moves a pre-App-Group store into the shared container, once.
    ///
    /// Without this, shipping the widget would silently empty every existing
    /// reader's library: the app would open a brand-new store at the shared
    /// path and the old one would sit there unreferenced. Copies rather than
    /// moves, so a failure part-way leaves the original intact.
    static func migrateLegacyStoreIfNeeded() {
        guard let shared = AppGroup.sharedStoreURL() else { return }
        let fileManager = FileManager.default
        let legacy = legacyStoreURL()

        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: shared.path) else { return }

        // SwiftData/SQLite keeps sidecar files; all three have to travel or
        // the copied store opens as corrupt.
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            let to = URL(fileURLWithPath: shared.path + suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            try? fileManager.copyItem(at: from, to: to)
        }
    }

    /// The app's container. Falls back to an in-memory store rather than
    /// refusing to launch: a reader with a broken store should still be able to
    /// open the app and read something.
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = makeSchema()

        if !inMemory {
            migrateLegacyStoreIfNeeded()
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
