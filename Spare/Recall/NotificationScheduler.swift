import Foundation
import SwiftData
import SpareCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Schedules at most one local notification: a reminder that fires only on a
/// day something is actually due, at the user's chosen time, naming the
/// specific lesson it's about.
///
/// This is a locally-computed schedule-ahead approximation, not a live
/// "verify at fire time" system — there is no server and no Notification
/// Service Extension in this v1, so freshness comes from recomputing and
/// re-scheduling the single pending notification every time recall state
/// changes (a new item generated, an item answered) or the app returns to
/// the foreground, rather than a check the OS runs at the moment of
/// delivery. In the ordinary flow this is exact: answering a recall item
/// requires opening the app, which is exactly when the next reschedule
/// happens.
enum NotificationScheduler {
    /// Fixed and singular: there is never more than one pending request, so
    /// rescheduling is always "remove this one, maybe add it back."
    static let identifier = "spare.recall-reminder"

    /// 9:00 AM. A plausible default; changeable in Settings.
    static let defaultMinutesSinceMidnight = 9 * 60

    static func reschedule(modelContext: ModelContext, calendar: Calendar = .current, now: Date = .now) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard let item = modelContext.nextRecallItem() else { return }

        // The deferred permission ask. There is now a real question waiting,
        // so the prompt can explain itself; before this it fired during
        // onboarding for a payoff a day away.
        requestPermissionIfNeeded()

        let minutes = UserDefaults.standard.object(forKey: AppSettingsKey.recallNotificationTimeMinutes) as? Int
            ?? defaultMinutesSinceMidnight
        let hour = minutes / 60
        let minute = minutes % 60

        // The chosen day is whichever is later: the item's own due date, or
        // today (for an item that's already overdue, which should still
        // remind today, not on its original — past — due date).
        let baseDay = max(item.dueAt, now)
        guard var fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDay) else {
            return
        }
        // If today's slot at the chosen time has already passed, the next
        // opportunity is the same time tomorrow — the item is still due.
        if fireDate < now {
            fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }

        let lessonTitle = modelContext.storedLesson(id: item.lessonID)?.title
        let content = UNMutableNotificationContent()
        content.title = "Spare"
        content.body = lessonTitle.map { "You read about \($0). One question." }
            ?? "You have a question waiting. One question."
        content.sound = .default

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        // `add` no-ops safely (via its completion handler) when notification
        // permission was never granted — nothing further to check here.
        center.add(request)
        #endif
    }

    #if DEBUG
    /// Ten seconds from now, so notification delivery can be verified in a
    /// sitting rather than tomorrow.
    ///
    /// The real schedule is a day out at the earliest and fires at a time the
    /// reader picked, which is right for the product and useless to anybody
    /// checking the plumbing works. Asks for permission directly rather than
    /// through `requestPermissionIfNeeded`, which deliberately fires at most
    /// once and only for a reader who opted in during onboarding.
    ///
    /// DEBUG only. It cannot reach a release build.
    static func sendTestNotification() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Spare"
            content.body = "Test reminder. If you can see this, delivery works."
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "spare.test.notification",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)
            ))
        }
        #endif
    }
    #endif

    /// Fires the system prompt at most once, and only for a reader who asked
    /// for reminders during onboarding.
    private static func requestPermissionIfNeeded() {
        #if canImport(UserNotifications)
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppSettingsKey.wantsRecallReminders),
              !defaults.bool(forKey: AppSettingsKey.hasRequestedNotificationPermission)
        else { return }
        defaults.set(true, forKey: AppSettingsKey.hasRequestedNotificationPermission)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }
}
