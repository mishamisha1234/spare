import Foundation
import SwiftData
import SpareCore

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

    /// Rewrites rows written under a window raw value the app no longer has.
    ///
    /// `TimeWindow.stored` already decodes those rows correctly, so nothing is
    /// broken without this. What it fixes is the data continuing to say
    /// something untrue: a lesson row still holding `"ten"` reads as a
    /// 7-minute explainer through the accessor and as an unknown window to
    /// anything that looks at `windowRaw` directly — the suggestion cache's
    /// `#Predicate` filters do exactly that, and a predicate cannot call
    /// `TimeWindow.stored`.
    ///
    /// The two models are treated differently on purpose.
    ///
    /// A lesson is the reader's library and is rewritten in place. Losing one
    /// because a length was renamed would be indefensible.
    ///
    /// A suggestion cache row is deleted. It is a cache — the Suggestions
    /// screen regenerates it in the background on the next visit — and
    /// deleting sidesteps the collision that renaming would create:
    /// `windowRaw` is `@Attribute(.unique)`, so rewriting a `"ten"` row to
    /// `"seven"` next to an existing `"seven"` row is a constraint violation
    /// that would fail the whole save, taking the lesson rewrites with it.
    ///
    /// Idempotent, and cheap when there is nothing to do: the fetches are
    /// filtered on the legacy values, so the common case reads nothing.
    @discardableResult
    static func normalizeLegacyWindows(in context: ModelContext) -> (lessons: Int, caches: Int) {
        // An Array, not a Set: `#Predicate` compiles `contains` against a
        // captured array, and a Set does not survive the translation to a
        // fetch predicate.
        let legacy = Array(TimeWindow.legacyRawValues.keys)
        guard !legacy.isEmpty else { return (0, 0) }

        var rewritten = 0
        let staleLessons = FetchDescriptor<StoredLesson>(
            predicate: #Predicate { legacy.contains($0.windowRaw) }
        )
        for lesson in (try? context.fetch(staleLessons)) ?? [] {
            guard let window = TimeWindow.stored(rawValue: lesson.windowRaw) else { continue }
            lesson.windowRaw = window.rawValue
            rewritten += 1
        }

        var dropped = 0
        let staleCaches = FetchDescriptor<StoredSuggestionCache>(
            predicate: #Predicate { legacy.contains($0.windowRaw) }
        )
        for cache in (try? context.fetch(staleCaches)) ?? [] {
            context.delete(cache)
            dropped += 1
        }

        if rewritten > 0 || dropped > 0 {
            try? context.save()
        }
        return (rewritten, dropped)
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
