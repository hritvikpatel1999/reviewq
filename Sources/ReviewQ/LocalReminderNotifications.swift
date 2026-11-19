import Foundation
import ReviewQCore
import UserNotifications

@MainActor
struct LocalReminderNotifications: ReminderNotifying {
    static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == "dev.prbar.app" else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }

    var isAvailable: Bool { Self.center != nil }

    func authorization() async -> ReminderAuthorization {
        guard let center = Self.center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws {
        guard let center = Self.center else { throw ReminderError.unavailable }
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingIdentifiers() async -> [String] {
        guard let center = Self.center else { return [] }
        return await center.pendingNotificationRequests().map(\.identifier)
    }

    func add(_ notification: ReminderNotification) async throws {
        guard let center = Self.center else { throw ReminderError.unavailable }
        try await center.add(Self.request(for: notification))
    }

    func removePending(identifiers: [String]) {
        Self.center?.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    static func request(for notification: ReminderNotification) throws -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Review reminder"
        content.body = "Take a moment to check your ReviewQ."
        content.threadIdentifier = "review-reminders"
        if notification.playsSound { content.sound = .default }
        let trigger: UNNotificationTrigger?
        switch notification.trigger {
        case .weekly(let weekday, let time):
            guard (1...7).contains(weekday) else { throw ReminderError.invalidDays }
            try time.validate()
            var components = DateComponents()
            components.weekday = weekday
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        case .test:
            trigger = nil
        }
        return UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger)
    }
}
