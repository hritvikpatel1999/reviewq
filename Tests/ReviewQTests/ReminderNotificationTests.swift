import Foundation
@testable import ReviewQ
@testable import ReviewQCore
import UserNotifications
import XCTest

@MainActor
final class ReminderNotificationTests: XCTestCase {
    func testWeeklyNotificationsUseRepeatingFloatingLocalCalendarTimesAndNoPrivatePayload() throws {
        let configuration = ReminderConfiguration(
            isEnabled: true, weekdays: [2, 6], times: [.init(hour: 10, minute: 30)]
        )
        let notifications = try configuration.notifications()
        for notification in notifications {
            let request = try LocalReminderNotifications.request(for: notification)
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertTrue(trigger.repeats)
            XCTAssertEqual(trigger.dateComponents.hour, 10)
            XCTAssertEqual(trigger.dateComponents.minute, 30)
            XCTAssertTrue([2, 6].contains(try XCTUnwrap(trigger.dateComponents.weekday)))
            XCTAssertNil(trigger.dateComponents.timeZone, "A recurring wall-clock reminder must follow the Mac's time zone.")
            XCTAssertNil(trigger.dateComponents.calendar, "Do not serialize a calendar with a pinned installation-time time zone.")
            XCTAssertNil(trigger.dateComponents.day)
            XCTAssertNil(trigger.dateComponents.month)
            XCTAssertNil(trigger.dateComponents.year)
            XCTAssertNotNil(trigger.nextTriggerDate())
            XCTAssertTrue(request.content.userInfo.isEmpty)
            XCTAssertTrue(request.content.attachments.isEmpty)
            XCTAssertNil(request.content.sound)
            XCTAssertEqual(request.content.body, "Take a moment to check your ReviewQ.")
        }
        XCTAssertNotEqual(notifications[0].identifier, notifications[1].identifier)
    }

    func testSoundIsExplicitAndTestsDeliverImmediatelyUsingTheSameGenericQueueAction() throws {
        let weekly = ReminderNotification(trigger: .weekly(weekday: 1, time: .init(hour: 0, minute: 0)), playsSound: true)
        let test = ReminderNotification(trigger: .test, playsSound: false)
        let scheduled = try LocalReminderNotifications.request(for: weekly)
        let preview = try LocalReminderNotifications.request(for: test)
        XCTAssertNotNil(scheduled.content.sound)
        XCTAssertNil(preview.content.sound)
        XCTAssertNil(preview.trigger)
        XCTAssertEqual(preview.content.body, scheduled.content.body)
        XCTAssertEqual(preview.content.title, scheduled.content.title)
        XCTAssertEqual(preview.identifier, ReminderNotification.testIdentifier)
        XCTAssertThrowsError(try LocalReminderNotifications.request(for:
            .init(trigger: .weekly(weekday: 0, time: .init(hour: 10, minute: 30)), playsSound: false)
        ))
    }
}
