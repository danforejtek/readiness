import Foundation
import OSLog
import UserNotifications

private let log = Logger(subsystem: "com.danforejtek.readiness", category: "reminder")

/// Morning reminder. Instead of one repeating notification, single notifications are planned for the next
/// 30 days, so today's can be dropped once you have measured. Re-planned whenever the app becomes active
/// or a measurement finishes.
enum ReminderService {
    static let idPrefix = "morning-reminder-"
    static let daysAhead = 30

    /// Asks for permission; returns whether notifications may be shown.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    /// When the next planned reminder fires, as iOS has it scheduled.
    static func nextFireDate() async -> Date? {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(idPrefix) }
            .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }
            .min()
    }

    static func reschedule(measuredToday: Bool, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        let authorized = await isAuthorized()
        log.info("replan: enabled=\(AppSettings.reminderEnabled) authorized=\(authorized) measuredToday=\(measuredToday) removed=\(ours.count)")
        guard AppSettings.reminderEnabled, authorized else {
            await MainActor.run { AppRouter.shared.nextReminder = nil }
            return
        }

        let cal = Calendar.current
        let minutes = AppSettings.reminderMinutes
        let today = cal.startOfDay(for: now)
        for offset in 0..<daysAhead {
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  let fire = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day),
                  fire > now, !(offset == 0 && measuredToday) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Morning HRV"
            content.body = "Before you get up: put the band on, lie still and measure for two minutes."
            content.sound = .default
            content.userInfo = ["action": "measure"]
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
            let id = idPrefix + ISO8601DateFormatter().string(from: fire)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                log.error("could not schedule \(id): \(error.localizedDescription)")
            }
        }
        let next = await nextFireDate()
        let pending = await center.pendingNotificationRequests().count
        log.info("replan done: pending=\(pending) next=\(String(describing: next))")
        await MainActor.run { AppRouter.shared.nextReminder = next }
    }
}
