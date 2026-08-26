import Foundation
import SwiftUI

/// Every preference this app persists, and the only place one may be declared.
///
/// A registry rather than a set of constants. `resetAll` iterates `allCases`,
/// so a key cannot be added without becoming resettable, and a CI guard bans
/// `@AppStorage("…")` and `forKey: "…"` string literals in the app target so a
/// key cannot be added without going through here at all.
///
/// Both halves are needed. The enum alone would still let somebody write a raw
/// literal at a call site; the guard alone would still let a declared key be
/// left out of a hand-maintained reset list, which is exactly what happened
/// with the trial's four flags.
enum AppSettingsKey: String, CaseIterable {
    case appearanceMode = "appearanceMode"
    case textSizeStep = "textSizeStep"
    case hasCompletedOnboarding = "hasCompletedOnboarding"
    /// Minutes since midnight, local time. Default is 9:00 AM (540); see
    /// `NotificationScheduler.defaultMinutesSinceMidnight`.
    case recallNotificationTimeMinutes = "recallNotificationTimeMinutes"
    /// Whether the reader opted in during onboarding. Intent is stored there;
    /// the system prompt is deferred until a question is genuinely due.
    case wantsRecallReminders = "wantsRecallReminders"
    /// Set once the system prompt has actually been shown, so a decline
    /// isn't re-asked on every subsequent due question.
    case hasRequestedNotificationPermission = "hasRequestedNotificationPermission"
    /// Set the first time the paywall is shown after a completed lesson, so
    /// the day-0 ask happens exactly once. The ordering rule -- never before
    /// the first complete lesson -- is enforced separately, by the presence
    /// of a completed lesson; this only stops it repeating.
    case hasShownFirstLessonPaywall = "hasShownFirstLessonPaywall"
    /// Set once the free week has been offered, so declining the paywall a
    /// second time does not re-announce a trial the reader already has.
    case hasOfferedTrial = "hasOfferedTrial"
    /// The day-4 progress line. Dismissible and shown once, per the spec:
    /// it is a report, and a report that keeps coming back is a nag.
    case hasDismissedTrialNudge = "hasDismissedTrialNudge"
    /// Set once the day-7 summary has been shown, so it appears on the first
    /// open after expiry and not on every launch afterwards.
    case hasShownTrialSummary = "hasShownTrialSummary"

    /// Clears every key this app declares.
    ///
    /// Driven by `allCases`, so a key cannot exist without being resettable.
    /// The previous version was a hand-written list beside this enum, and four
    /// keys were added without being added to it -- which meant the second and
    /// third launches of a UI test ran on the first one's leftovers, and the
    /// test that found it took three CI rounds to diagnose. Adding a key to
    /// this enum is now the whole of the work.
    ///
    /// What is deliberately *not* here: `DeviceIdentity`'s identifier. It
    /// lives in the App Group suite under its own key and is not an app
    /// setting -- clearing it would hand every UI-test launch a new device and
    /// a fresh free allowance, which is the opposite of a clean slate. If a
    /// key ever does need to survive a reset, it belongs in this file as an
    /// explicit exclusion rather than as an omission from a list.
    static func resetAll(in defaults: UserDefaults) {
        for key in allCases { defaults.removeObject(forKey: key.rawValue) }
    }
}

// MARK: - Reading and writing without a string literal
//
// The overloads below are what let the CI guard be absolute: `@AppStorage("…")`
// and `forKey: "…"` are banned outright in the app target, so there is no way
// to persist anything that `resetAll` does not know about. Without them every
// call site would carry `.rawValue` and the guard would have to allow a
// literal somewhere.

/// `@AppStorage(.hasCompletedOnboarding)` instead of `@AppStorage("…")`.
///
/// One overload per stored type. The `wrappedValue:` label is what SwiftUI
/// synthesises for a property with a default, so these have to take it even
/// though every call site writes the default on the right-hand side.
extension AppStorage where Value == Bool {
    init(wrappedValue: Value, _ key: AppSettingsKey, store: UserDefaults? = nil) {
        self.init(wrappedValue: wrappedValue, key.rawValue, store: store)
    }
}

extension AppStorage where Value == Int {
    init(wrappedValue: Value, _ key: AppSettingsKey, store: UserDefaults? = nil) {
        self.init(wrappedValue: wrappedValue, key.rawValue, store: store)
    }
}

extension AppStorage where Value == String {
    init(wrappedValue: Value, _ key: AppSettingsKey, store: UserDefaults? = nil) {
        self.init(wrappedValue: wrappedValue, key.rawValue, store: store)
    }
}

extension AppStorage where Value == Double {
    init(wrappedValue: Value, _ key: AppSettingsKey, store: UserDefaults? = nil) {
        self.init(wrappedValue: wrappedValue, key.rawValue, store: store)
    }
}

extension UserDefaults {
    func bool(forKey key: AppSettingsKey) -> Bool { bool(forKey: key.rawValue) }
    func integer(forKey key: AppSettingsKey) -> Int { integer(forKey: key.rawValue) }
    func string(forKey key: AppSettingsKey) -> String? { string(forKey: key.rawValue) }
    func object(forKey key: AppSettingsKey) -> Any? { object(forKey: key.rawValue) }
    func set(_ value: Bool, forKey key: AppSettingsKey) { set(value, forKey: key.rawValue) }
    func set(_ value: Int, forKey key: AppSettingsKey) { set(value, forKey: key.rawValue) }
    func set(_ value: String, forKey key: AppSettingsKey) { set(value, forKey: key.rawValue) }
}

/// Reader text size: a small fixed set of steps, like Kindle's "Aa" control.
/// Only these four multipliers exist — no continuous slider.
enum TextSizeStep: Int, CaseIterable, Identifiable {
    case small = 0
    case standard = 1
    case large = 2
    case extraLarge = 3

    var id: Int { rawValue }

    var multiplier: Double {
        switch self {
        case .small: 0.88
        case .standard: 1.0
        case .large: 1.15
        case .extraLarge: 1.32
        }
    }

    var label: String {
        switch self {
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}
