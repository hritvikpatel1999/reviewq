import Combine
import Foundation

@MainActor
public final class ReminderStore: ObservableObject {
    public static let settingsKey = "reviewReminders"
    private static let maximumSettingsBytes = 16 * 1024
    @Published public private(set) var configuration = ReminderConfiguration()
    @Published public private(set) var authorization = ReminderAuthorization.notDetermined
    @Published public private(set) var isWorking = false
    @Published public private(set) var isScheduled = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var testRequested = false
    private let notifications: any ReminderNotifying
    private let defaults: UserDefaults
    private let diagnostics: DiagnosticLogger
    private var work: Task<Void, Never>?
    private var needsSynchronization = false
    private var permissionRequested = false
    private var pendingTestSound: Bool?
    private var forceReschedule = false
    private var revision = 0
    private var appliedConfiguration: ReminderConfiguration?
    private var restoredSettingsError: String?

    public init(
        notifications: any ReminderNotifying, defaults: UserDefaults = .standard,
        diagnostics: DiagnosticLogger = .disabled
    ) {
        self.notifications = notifications
        self.defaults = defaults
        self.diagnostics = diagnostics
        guard defaults.object(forKey: Self.settingsKey) != nil else { return }
        do {
            guard let data = defaults.data(forKey: Self.settingsKey), data.count <= Self.maximumSettingsBytes else {
                throw ReminderError.corruptSettings
            }
            let saved = try JSONDecoder().decode(SavedConfiguration.self, from: data)
            guard saved.version == 1 else { throw ReminderError.corruptSettings }
            try saved.configuration.validate()
            configuration = saved.configuration
        } catch {
            restoredSettingsError = ReminderError.corruptSettings.localizedDescription
            errorMessage = restoredSettingsError
            diagnostics.log(.warning, .reminderSettingsInvalidated, operation: .reminders, reason: .corruptSettings)
        }
    }

    public func save(_ configuration: ReminderConfiguration) throws {
        do {
            try configuration.validate()
            let data = try JSONEncoder().encode(SavedConfiguration(version: 1, configuration: configuration))
            guard data.count <= Self.maximumSettingsBytes else { throw ReminderError.corruptSettings }
            defaults.set(data, forKey: Self.settingsKey)
            self.configuration = configuration
            revision += 1
            restoredSettingsError = nil
            errorMessage = nil
            diagnostics.log(.info, .reminderSettingsSaved, operation: .reminders)
            requestSynchronization()
        } catch {
            diagnostics.logFailure(.reminderFailed, error: error, operation: .reminders)
            throw error
        }
    }

    public func requestSynchronization(force: Bool = false) {
        needsSynchronization = true
        forceReschedule = forceReschedule || force
        startWork()
    }

    public func requestPermission() {
        permissionRequested = true
        requestSynchronization()
    }

    public func sendTest(playsSound: Bool) {
        pendingTestSound = playsSound
        testRequested = false
        requestSynchronization()
    }

    public func waitUntilIdle() async {
        while let work { await work.value }
    }

    private func startWork() {
        guard work == nil else { return }
        isWorking = true
        work = Task { [weak self] in
            guard let self else { return }
            while needsSynchronization {
                needsSynchronization = false
                let askPermission = permissionRequested
                let testSound = pendingTestSound
                let force = forceReschedule
                permissionRequested = false
                pendingTestSound = nil
                forceReschedule = false
                do {
                    try await synchronize(askPermission: askPermission, testSound: testSound, force: force)
                    errorMessage = restoredSettingsError
                } catch {
                    errorMessage = error.localizedDescription
                    diagnostics.logFailure(
                        (error as? ReminderError)?.diagnosticEvent ?? .reminderFailed,
                        error: error, operation: .reminders
                    )
                }
            }
            isWorking = false
            work = nil
        }
    }

    private func synchronize(askPermission: Bool, testSound: Bool?, force: Bool) async throws {
        let currentRevision = revision
        guard notifications.isAvailable else {
            authorization = .unavailable
            isScheduled = false
            if configuration.isEnabled || askPermission || testSound != nil { throw ReminderError.unavailable }
            return
        }
        authorization = await notifications.authorization()
        if askPermission, authorization == .notDetermined {
            do { try await notifications.requestAuthorization() }
            catch { throw ReminderError.authorizationFailed(DiagnosticFailure(error)) }
            authorization = await notifications.authorization()
        }
        guard revision == currentRevision else { return }
        let pending = await notifications.pendingIdentifiers()
        guard revision == currentRevision else { return }
        let owned = pending.filter { $0.hasPrefix(ReminderNotification.identifierPrefix) }
        let weekly = owned.filter { $0 != ReminderNotification.testIdentifier }
        let requests = try configuration.notifications()
        if !configuration.isEnabled || authorization != .authorized {
            notifications.removePending(identifiers: owned)
            appliedConfiguration = nil
            isScheduled = false
        } else if force || appliedConfiguration != configuration || Set(weekly) != Set(requests.map(\.identifier)) {
            isScheduled = false
            appliedConfiguration = nil
            notifications.removePending(identifiers: weekly)
            do {
                for request in requests {
                    try await notifications.add(request)
                    guard revision == currentRevision else { return }
                }
            } catch {
                notifications.removePending(identifiers: requests.map(\.identifier))
                throw ReminderError.schedulingFailed(DiagnosticFailure(error))
            }
            appliedConfiguration = configuration
            isScheduled = true
            diagnostics.log(.info, .remindersScheduled, operation: .reminders, count: requests.count)
        }
        if configuration.isEnabled || askPermission || testSound != nil {
            switch authorization {
            case .denied: throw ReminderError.denied
            case .notDetermined: throw ReminderError.permissionRequired
            case .unavailable: throw ReminderError.unavailable
            case .authorized: break
            }
        }
        if let testSound {
            do { try await notifications.add(ReminderNotification(trigger: .test, playsSound: testSound)) }
            catch { throw ReminderError.testFailed(DiagnosticFailure(error)) }
            testRequested = true
            diagnostics.log(.info, .reminderTestRequested, operation: .reminders)
        }
    }

    private struct SavedConfiguration: Codable {
        let version: Int
        let configuration: ReminderConfiguration
    }
}
