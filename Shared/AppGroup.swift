import Foundation

/// Everything both the app and the widget extension need to agree on.
///
/// Compiled into *both* targets. The widget runs in its own process with its
/// own container, so anything it reads has to live somewhere both processes
/// can reach — that is the entire job of the App Group.
enum AppGroup {

    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both `Spare.entitlements` and `SpareWidget.entitlements`. If either
    /// one is missing or misspelled, `containerURL` below returns nil and the
    /// widget silently reads an empty database — the exact failure this
    /// identifier being in one shared file is meant to prevent.
    static let identifier = "group.app.spare.ios"

    /// The shared container, or nil when the entitlement isn't in effect.
    ///
    /// Nil is a real case, not just a defensive shrug: unsigned builds (CI
    /// runs with `CODE_SIGNING_ALLOWED=NO`) don't get App Group entitlements
    /// applied at all. The app has to keep working there, so callers fall
    /// back to their own container rather than trapping.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where the SwiftData store lives when the group is available.
    static func sharedStoreURL() -> URL? {
        guard let container = containerURL else { return nil }
        return container.appending(path: "Spare.store")
    }

    /// True when the widget can actually see the app's data. Surfaced in
    /// Settings rather than left as a silent condition, because "the widget
    /// shows zero" is otherwise indistinguishable from "you have no lessons".
    static var isSharedStorageAvailable: Bool {
        containerURL != nil
    }
}
