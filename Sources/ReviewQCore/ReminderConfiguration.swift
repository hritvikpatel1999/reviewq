import Foundation

public struct ReminderTime: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var minuteOfDay: Int { hour * 60 + minute }

    public func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw ReminderError.invalidTime }
    }
}

public struct ReminderConfiguration: Codable, Equatable, Sendable {
    public static let maximumTimes = 8
    public var isEnabled: Bool
    public var weekdays: Set<Int>
    public var times: [ReminderTime]
    public var playsSound: Bool

    public init(
        isEnabled: Bool = false, weekdays: Set<Int> = [2, 3, 4, 5, 6],
        times: [ReminderTime] = [.init(hour: 10, minute: 30), .init(hour: 15, minute: 30)],
        playsSound: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.weekdays = weekdays
        self.times = times
        self.playsSound = playsSound
    }

    public func validate() throws {
        guard weekdays.isSubset(of: Set(1...7)), !isEnabled || !weekdays.isEmpty else {
            throw ReminderError.invalidDays
        }
        guard times.count <= Self.maximumTimes else { throw ReminderError.tooManyTimes }
        guard !isEnabled || !times.isEmpty else { throw ReminderError.missingTimes }
        try times.forEach { try $0.validate() }
        guard Set(times).count == times.count else { throw ReminderError.duplicateTime }
    }

    public func notifications() throws -> [ReminderNotification] {
        try validate()
        guard isEnabled else { return [] }
        return weekdays.sorted().flatMap { day in
            times.sorted { $0.minuteOfDay < $1.minuteOfDay }.map {
                ReminderNotification(trigger: .weekly(weekday: day, time: $0), playsSound: playsSound)
            }
        }
    }
}

public struct ReminderNotification: Equatable, Sendable {
    public enum Trigger: Equatable, Sendable {
        case weekly(weekday: Int, time: ReminderTime)
        case test
    }

    public static let identifierPrefix = "dev.prbar.app.review-reminder."
    public static let testIdentifier = identifierPrefix + "test"
    public let trigger: Trigger
    public let playsSound: Bool

    public init(trigger: Trigger, playsSound: Bool) {
        self.trigger = trigger
        self.playsSound = playsSound
    }

    public var identifier: String {
        switch trigger {
        case .weekly(let day, let time): Self.identifierPrefix + "\(day).\(time.minuteOfDay)"
        case .test: Self.testIdentifier
        }
    }
}

public enum ReminderAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied, unavailable
}

@MainActor
public protocol ReminderNotifying {
    var isAvailable: Bool { get }
    func authorization() async -> ReminderAuthorization
    func requestAuthorization() async throws
    func pendingIdentifiers() async -> [String]
    func add(_ notification: ReminderNotification) async throws
    func removePending(identifiers: [String])
}

public enum ReminderError: LocalizedError {
    case invalidDays, missingTimes, tooManyTimes, invalidTime, duplicateTime
    case unavailable, denied, permissionRequired, corruptSettings
    case authorizationFailed(DiagnosticFailure), schedulingFailed(DiagnosticFailure), testFailed(DiagnosticFailure)

    public var errorDescription: String? {
        switch self {
        case .invalidDays: "Select at least one valid day for review reminders."
        case .missingTimes: "Add at least one reminder time."
        case .tooManyTimes: "Choose up to eight reminder times per selected day."
        case .invalidTime: "Choose a valid hour and minute for every reminder."
        case .duplicateTime: "Choose different times for each reminder."
        case .unavailable: "Run the built ReviewQ app to use macOS notifications."
        case .denied: "macOS notifications are blocked. Allow ReviewQ in System Settings > Notifications before reminders can be delivered."
        case .permissionRequired: "Allow macOS notifications to receive review reminders. No permission prompt appears until you choose to allow them."
        case .authorizationFailed: "macOS could not request notification permission. Try again or check System Settings > Notifications."
        case .schedulingFailed: "macOS could not schedule review reminders. No partial schedule was kept. Use Retry to apply your saved schedule."
        case .testFailed: "macOS could not send the test notification. Try again."
        case .corruptSettings: "Saved reminder settings could not be read. Reminders are off. Check and save your choices to replace them."
        }
    }

    var diagnosticReason: DiagnosticReason {
        switch self {
        case .invalidDays, .missingTimes, .tooManyTimes, .invalidTime, .duplicateTime: .invalidConfiguration
        case .denied: .forbidden
        case .permissionRequired: .approvalPending
        case .corruptSettings: .corruptSettings
        default: .system
        }
    }

    var underlyingDiagnostic: DiagnosticFailure? {
        switch self {
        case .authorizationFailed(let failure), .schedulingFailed(let failure), .testFailed(let failure): failure
        default: nil
        }
    }

    var diagnosticEvent: DiagnosticEvent {
        switch self {
        case .authorizationFailed, .denied, .permissionRequired: .reminderAuthorizationFailed
        case .schedulingFailed: .reminderSchedulingFailed
        case .testFailed: .reminderTestFailed
        default: .reminderFailed
        }
    }
}
