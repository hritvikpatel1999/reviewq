import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class ReminderStoreTests: XCTestCase {
    func testExistingInstallationsStayOptedOutAndStartupCancelsOnlyOwnedRequestsWithoutPrompting() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        center.pending = ["other.feature": .init(trigger: .test, playsSound: false)]
        center.pending[ReminderNotification.identifierPrefix + "old"] = .init(trigger: .test, playsSound: false)
        let store = ReminderStore(notifications: center, defaults: defaults)
        store.requestSynchronization()
        await store.waitUntilIdle()
        XCTAssertFalse(store.configuration.isEnabled)
        XCTAssertFalse(store.configuration.playsSound)
        XCTAssertEqual(center.permissionRequests, 0)
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(Set(center.pending.keys), ["other.feature"])
        XCTAssertNil(defaults.object(forKey: ReminderStore.settingsKey))
        XCTAssertNil(store.errorMessage)
    }

    func testScheduleValidationAndTheMaximumProduceUniqueBoundedWeeklyRequests() throws {
        var maximum = ReminderConfiguration(
            isEnabled: true, weekdays: Set(1...7),
            times: (0..<8).map { ReminderTime(hour: $0, minute: 30) }
        )
        let requests = try maximum.notifications()
        XCTAssertEqual(requests.count, 56, "Eight times on seven days must fit below the system pending-request budget.")
        XCTAssertEqual(Set(requests.map(\.identifier)).count, requests.count)
        maximum.times.reverse()
        XCTAssertEqual(try maximum.notifications(), requests, "Changing row order must not create new notification identities.")
        var invalid = [ReminderConfiguration(isEnabled: true, weekdays: []), .init(isEnabled: true, times: [])]
        for time in [ReminderTime(hour: 24, minute: 0), .init(hour: 0, minute: 60), .init(hour: .max, minute: 0)] {
            invalid.append(.init(isEnabled: true, times: [time]))
        }
        invalid.append(.init(isEnabled: true, weekdays: [0, 8]))
        invalid.append(.init(isEnabled: true, times: [.init(hour: 9, minute: 0), .init(hour: 9, minute: 0)]))
        maximum.times.append(.init(hour: 20, minute: 0))
        invalid.append(maximum)
        for configuration in invalid { XCTAssertThrowsError(try configuration.notifications()) }
    }

    func testSavedOptInNeverPromptsOnStartupButExplicitPermissionSchedulesAndPersistsTheChoices() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        let store = ReminderStore(notifications: center, defaults: defaults)
        let configuration = ReminderConfiguration(
            isEnabled: true, weekdays: [2, 6],
            times: [.init(hour: 9, minute: 15), .init(hour: 16, minute: 45)], playsSound: true
        )
        try store.save(configuration)
        await store.waitUntilIdle()
        XCTAssertEqual(center.permissionRequests, 0)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        store.requestPermission()
        await store.waitUntilIdle()
        XCTAssertEqual(center.permissionRequests, 1)
        XCTAssertEqual(center.pending, Dictionary(uniqueKeysWithValues: try configuration.notifications().map { ($0.identifier, $0) }))
        XCTAssertTrue(store.isScheduled)
        XCTAssertNil(store.errorMessage)
        let reopened = ReminderStore(notifications: center, defaults: defaults)
        XCTAssertEqual(reopened.configuration, configuration)
        reopened.requestSynchronization()
        await reopened.waitUntilIdle()
        XCTAssertEqual(center.permissionRequests, 1, "Restoring or reopening must never request permission.")
        XCTAssertEqual(center.pending.count, 4)
        XCTAssertTrue(reopened.isScheduled)
    }

    func testDeniedPermissionsStayVisibleDoNotRepromptAndRecoverAfterSystemSettingsChange() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        center.permissionResult = .denied
        let store = ReminderStore(notifications: center, defaults: defaults)
        try store.save(ReminderConfiguration(isEnabled: true))
        store.requestPermission()
        await store.waitUntilIdle()
        XCTAssertEqual(store.authorization, .denied)
        XCTAssertFalse(store.isScheduled)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("blocked"))
        store.requestPermission()
        await store.waitUntilIdle()
        XCTAssertEqual(center.permissionRequests, 1, "macOS must not be asked to prompt again after denial.")
        center.status = .authorized
        store.requestSynchronization()
        await store.waitUntilIdle()
        XCTAssertTrue(store.isScheduled)
        XCTAssertEqual(center.pending.count, 10)
        XCTAssertNil(store.errorMessage)
    }

    func testPartialSchedulingFailuresRollBackAndRetrySoundChangesAndOptOutReplaceOnlyOwnedRequests() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        center.status = .authorized
        center.pending["other.feature"] = .init(trigger: .test, playsSound: false)
        center.failAtAdd = 2
        let store = ReminderStore(notifications: center, defaults: defaults)
        var configuration = ReminderConfiguration(isEnabled: true)
        try store.save(configuration)
        await store.waitUntilIdle()
        XCTAssertFalse(store.isScheduled)
        XCTAssertEqual(Set(center.pending.keys), ["other.feature"])
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("No partial schedule"))
        center.failAtAdd = nil
        store.requestSynchronization()
        await store.waitUntilIdle()
        XCTAssertEqual(center.pending.count, 11)
        let additions = center.added.count
        store.requestSynchronization()
        await store.waitUntilIdle()
        XCTAssertEqual(center.added.count, additions, "Activation must not replace an unchanged valid schedule.")
        configuration.playsSound = true
        try store.save(configuration)
        await store.waitUntilIdle()
        XCTAssertTrue(center.pending.filter { $0.key != "other.feature" }.values.allSatisfy(\.playsSound))
        configuration.isEnabled = false
        try store.save(configuration)
        await store.waitUntilIdle()
        XCTAssertEqual(Set(center.pending.keys), ["other.feature"])
        XCTAssertFalse(store.isScheduled)
        XCTAssertNil(store.errorMessage)
    }

    func testOptingOutWhileAnAddIsInFlightCannotLeaveAnOldReminderBehind() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        center.status = .authorized
        center.holdNextAdd = true
        let store = ReminderStore(notifications: center, defaults: defaults)
        try store.save(ReminderConfiguration(isEnabled: true))
        await center.waitForHeldAdd()
        try store.save(ReminderConfiguration())
        center.releaseAdd()
        await store.waitUntilIdle()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertFalse(store.isScheduled)
        XCTAssertFalse(store.configuration.isEnabled)
        XCTAssertNil(store.errorMessage)
    }

    func testTestNotificationsAreExplicitCanPreviewAnUnsavedScheduleAndDoNotEnableReminders() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        center.status = .authorized
        let store = ReminderStore(notifications: center, defaults: defaults)
        store.sendTest(playsSound: false)
        await store.waitUntilIdle()
        XCTAssertTrue(store.testRequested)
        XCTAssertEqual(center.added.count, 1)
        XCTAssertEqual(center.added.first?.trigger, .test)
        XCTAssertEqual(center.added.first?.playsSound, false)
        XCTAssertFalse(store.configuration.isEnabled)
        XCTAssertNil(defaults.object(forKey: ReminderStore.settingsKey))
        XCTAssertEqual(center.permissionRequests, 0)
    }

    func testCorruptSettingsFailClosedRemainVisibleAndAreReplacedOnlyByAValidSave() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = Data("invalid reminder preferences".utf8)
        defaults.set(invalid, forKey: ReminderStore.settingsKey)
        let center = ReminderCenterFake()
        let store = ReminderStore(notifications: center, defaults: defaults)
        store.requestSynchronization()
        await store.waitUntilIdle()
        XCTAssertFalse(store.configuration.isEnabled)
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("could not be read"))
        XCTAssertEqual(defaults.data(forKey: ReminderStore.settingsKey), invalid)
        XCTAssertThrowsError(try store.save(.init(isEnabled: true, weekdays: [])))
        XCTAssertEqual(defaults.data(forKey: ReminderStore.settingsKey), invalid)
        try store.save(ReminderConfiguration())
        await store.waitUntilIdle()
        XCTAssertNil(store.errorMessage)
        XCTAssertNotEqual(defaults.data(forKey: ReminderStore.settingsKey), invalid)
        XCTAssertEqual(center.permissionRequests, 0)
    }

    func testAuthorizationAndTestFailuresAreNotReportedAsSuccess() async throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ReminderCenterFake()
        center.failPermission = true
        let store = ReminderStore(notifications: center, defaults: defaults)
        store.requestPermission()
        await store.waitUntilIdle()
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("could not request"))
        XCTAssertFalse(store.isScheduled)
        center.status = .authorized
        center.failAtAdd = 1
        store.sendTest(playsSound: true)
        await store.waitUntilIdle()
        XCTAssertFalse(store.testRequested)
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("could not send the test"))
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testNativeFailureStagesReachDefaultLogsOnceWithCodesAndWithoutPrivateDetails() async throws {
        let (defaults, suite) = try preferences()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ReviewQ-reminder-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove the test-owned reminder diagnostics directory.") }
        }
        let center = ReminderCenterFake()
        center.failure = NSError(
            domain: "UNErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_NOTIFICATION_DETAILS", "payload": "PRIVATE_NOTIFICATION_PAYLOAD"]
        )
        center.failPermission = true
        let logger = DiagnosticLogger(directory: directory)
        let store = ReminderStore(notifications: center, defaults: defaults, diagnostics: logger)
        store.requestPermission()
        await store.waitUntilIdle()
        center.status = .authorized
        center.failAtAdd = 1
        try store.save(.init(isEnabled: true, weekdays: [2], times: [.init(hour: 10, minute: 30)]))
        await store.waitUntilIdle()
        XCTAssertTrue(center.pending.isEmpty, "A failed scheduling attempt must still roll back.")
        center.failAtAdd = nil
        store.requestSynchronization()
        await store.waitUntilIdle()
        XCTAssertTrue(store.isScheduled)
        center.failAtAdd = center.added.count + 1
        store.sendTest(playsSound: false)
        await store.waitUntilIdle()
        XCTAssertFalse(store.testRequested)
        XCTAssertEqual(center.pending.count, 1, "A failed test must leave the saved schedule intact.")
        logger.flush()
        let data = try Data(contentsOf: directory.appendingPathComponent("warnings-errors.log"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try data.split(separator: 0x0a).map { try decoder.decode(DiagnosticRecord.self, from: Data($0)) }
        XCTAssertEqual(records.map(\.event), [.reminderAuthorizationFailed, .reminderSchedulingFailed, .reminderTestFailed])
        XCTAssertTrue(records.allSatisfy { $0.level == .warning && $0.operation == .reminders && $0.systemCode == 1 })
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("PRIVATE_NOTIFICATION_DETAILS"))
        XCTAssertFalse(text.contains("PRIVATE_NOTIFICATION_PAYLOAD"))
        XCTAssertFalse(try XCTUnwrap(store.errorMessage).contains("PRIVATE_NOTIFICATION"))
    }

    func testCancelledSchedulingRemainsInformationalAfterRollback() async throws {
        let (defaults, suite) = try preferences()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ReviewQ-reminder-cancellation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove the test-owned reminder diagnostics directory.") }
        }
        let center = ReminderCenterFake()
        center.status = .authorized
        center.failure = CancellationError()
        center.failAtAdd = 1
        let logger = DiagnosticLogger(directory: directory, verboseEnabled: true)
        let store = ReminderStore(notifications: center, defaults: defaults, diagnostics: logger)
        try store.save(.init(isEnabled: true))
        await store.waitUntilIdle()
        logger.flush()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertFalse(store.isScheduled)
        XCTAssertTrue(try Data(contentsOf: directory.appendingPathComponent("warnings-errors.log")).isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try Data(contentsOf: directory.appendingPathComponent("verbose.log"))
            .split(separator: 0x0a).map { try decoder.decode(DiagnosticRecord.self, from: Data($0)) }
        let failure = try XCTUnwrap(records.first { $0.event == .reminderSchedulingFailed })
        XCTAssertEqual(failure.level, .info)
        XCTAssertEqual(failure.reason, .cancelled)
        XCTAssertNil(failure.systemCode)
    }

    private func preferences() throws -> (UserDefaults, String) {
        let suite = "ReviewQ-reminder-tests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}

@MainActor
private final class ReminderCenterFake: ReminderNotifying {
    var isAvailable = true
    var status = ReminderAuthorization.notDetermined
    var permissionResult = ReminderAuthorization.authorized
    var permissionRequests = 0
    var failPermission = false
    var failAtAdd: Int?
    var failure: any Error = CocoaError(.featureUnsupported)
    var pending: [String: ReminderNotification] = [:]
    var added: [ReminderNotification] = []
    var holdNextAdd = false
    private var heldAdd: CheckedContinuation<Void, Never>?

    func authorization() async -> ReminderAuthorization { status }
    func requestAuthorization() async throws {
        permissionRequests += 1
        if failPermission { throw failure }
        status = permissionResult
    }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func removePending(identifiers: [String]) {
        for identifier in identifiers { pending.removeValue(forKey: identifier) }
    }
    func add(_ notification: ReminderNotification) async throws {
        added.append(notification)
        if added.count == failAtAdd { throw failure }
        if holdNextAdd {
            holdNextAdd = false
            await withCheckedContinuation { heldAdd = $0 }
        }
        pending[notification.identifier] = notification
    }
    func waitForHeldAdd() async { while heldAdd == nil { await Task.yield() } }
    func releaseAdd() { heldAdd?.resume(); heldAdd = nil }
}
