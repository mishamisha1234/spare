import Foundation

/// Central place for the small persisted preferences that predate a full
/// Settings screen (Phase 5/6). Wraps `UserDefaults` keys so call sites never
/// repeat a string literal.
enum AppSettingsKey {
    static let appearanceMode = "appearanceMode"
    static let textSizeStep = "textSizeStep"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"
    /// Minutes since midnight, local time. Default is 9:00 AM (540); see
    /// `NotificationScheduler.defaultMinutesSinceMidnight`.
    static let recallNotificationTimeMinutes = "recallNotificationTimeMinutes"
    /// Whether the reader opted in during onboarding. Intent is stored there;
    /// the system prompt is deferred until a question is genuinely due.
    static let wantsRecallReminders = "wantsRecallReminders"
    /// Set once the system prompt has actually been shown, so a decline
    /// isn't re-asked on every subsequent due question.
    static let hasRequestedNotificationPermission = "hasRequestedNotificationPermission"
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
