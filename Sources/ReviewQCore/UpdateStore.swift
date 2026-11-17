import Combine
import Foundation
import OSLog

@MainActor
public final class UpdateStore: ObservableObject {
    public static let settingsKey = "reviewAppUpdates"
    private static let checkInterval: TimeInterval = 24 * 3_600
    private static let maximumCacheBytes = 32 * 1_024

    @Published public private(set) var isChecking = false
    @Published public private(set) var errorMessage: String?
    @Published private var saved = SavedState()
    public let currentVersion: String?
    private let installedVersion: ReleaseVersion?
    private let client: any UpdateChecking
    private let defaults: UserDefaults
    private let diagnostics: DiagnosticLogger
    private let clock: () -> Date
    private let logger = Logger(subsystem: "dev.prbar.app", category: "app-updates")
    private var scheduledTask: Task<Void, Never>?

    public init(
        currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        defaults: UserDefaults = .standard, client: any UpdateChecking = GitHubUpdateClient(),
        diagnostics: DiagnosticLogger = .disabled, clock: @escaping () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.client = client
        self.diagnostics = diagnostics
        self.clock = clock
        do {
            guard let currentVersion else { throw UpdateCheckError.invalidVersion }
            let version = try ReleaseVersion(currentVersion)
            installedVersion = version
            self.currentVersion = version.description
        } catch {
            installedVersion = nil
            self.currentVersion = nil
        }
        restore()
        if installedVersion == nil {
            errorMessage = UpdateCheckError.invalidVersion.localizedDescription
            diagnostics.logFailure(.updateCheckFailed, error: UpdateCheckError.invalidVersion, operation: .appUpdates)
            logger.warning("Update checks require a packaged app with a valid version.")
        }
    }

    public var lastCheckedAt: Date? { saved.lastCheckedAt }

    public var availableUpdate: AvailableUpdate? {
        guard let installedVersion, let release = saved.release else { return nil }
        do {
            return try ReleaseVersion(release.version) > installedVersion ? release : nil
        } catch {
            diagnostics.logFailure(.updateCheckFailed, error: error, operation: .appUpdates)
            return nil
        }
    }

    public var bannerUpdate: AvailableUpdate? {
        guard let release = availableUpdate, release.version != saved.dismissedVersion else { return nil }
        return release
    }

    public func requestCheck(manually: Bool = false) {
        guard scheduledTask == nil, !isChecking else { return }
        scheduledTask = Task { [weak self] in
            await self?.check(manually: manually)
            self?.scheduledTask = nil
        }
    }

    public func cancel() {
        scheduledTask?.cancel()
    }

    public func dismissUpdate() {
        guard let release = availableUpdate else { return }
        saved.dismissedVersion = release.version
        persist()
    }

    public func check(manually: Bool = false) async {
        guard installedVersion != nil, !isChecking else { return }
        let now = clock()
        if let retryAt = saved.retryNotBefore, retryAt > now {
            if manually {
                errorMessage = "Update checks are paused by GitHub. Try again after "
                    + retryAt.formatted(date: .abbreviated, time: .shortened) + "."
            }
            return
        }
        guard manually || saved.nextCheckAt.map({ $0 <= now }) != false else { return }
        guard !Task.isCancelled else { return }
        isChecking = true
        errorMessage = nil
        diagnostics.log(.info, .updateCheckStarted, operation: .appUpdates)
        defer { isChecking = false }
        do {
            let result = try await client.check(entityTag: saved.entityTag)
            try Task.checkCancellation()
            switch result {
            case .modified(let release, let entityTag):
                if let release { _ = try AvailableUpdate(version: release.version, releaseURL: release.releaseURL) }
                if let entityTag, !GitHubUpdateClient.validEntityTag(entityTag) { throw UpdateCheckError.invalidResponse }
                saved.release = release
                saved.entityTag = entityTag
            case .notModified:
                guard saved.lastCheckedAt != nil, saved.entityTag != nil else {
                    throw UpdateCheckError.invalidResponse
                }
            }
            saved.lastCheckedAt = clock()
            saved.nextCheckAt = clock().addingTimeInterval(Self.checkInterval)
            saved.retryNotBefore = nil
            saved.failureCount = 0
            persist()
            diagnostics.log(.info, .updateCheckFinished, operation: .appUpdates)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                diagnostics.log(.info, .updateCheckCancelled, operation: .appUpdates, reason: .cancelled)
                return
            }
            saved.failureCount = min(saved.failureCount + 1, 8)
            let delay = min(Self.checkInterval, 15 * 60 * pow(2, Double(saved.failureCount - 1)))
            saved.nextCheckAt = clock().addingTimeInterval(delay)
            if case .http(_, let retryAt, _) = error as? UpdateCheckError {
                saved.retryNotBefore = retryAt
                if let retryAt, retryAt > (saved.nextCheckAt ?? clock()) { saved.nextCheckAt = retryAt }
            }
            errorMessage = error is URLError
                ? "Could not check for ReviewQ updates. Check your connection and try again."
                : error.localizedDescription
            persist()
            diagnostics.logFailure(.updateCheckFailed, error: error, operation: .appUpdates)
            logger.warning("Update checking failed. Cached update information is unchanged; check Diagnostics.")
        }
    }

    private func restore() {
        guard defaults.object(forKey: Self.settingsKey) != nil else { return }
        do {
            guard let data = defaults.data(forKey: Self.settingsKey), data.count <= Self.maximumCacheBytes else {
                throw UpdateCheckError.invalidCache
            }
            let state = try JSONDecoder().decode(SavedState.self, from: data)
            guard state.schema == 1, (0...8).contains(state.failureCount) else { throw UpdateCheckError.invalidCache }
            if let release = state.release {
                let validated = try AvailableUpdate(version: release.version, releaseURL: release.releaseURL)
                guard validated == release, state.lastCheckedAt != nil else { throw UpdateCheckError.invalidCache }
            }
            if let tag = state.entityTag {
                guard GitHubUpdateClient.validEntityTag(tag), state.lastCheckedAt != nil else {
                    throw UpdateCheckError.invalidCache
                }
            }
            if let dismissed = state.dismissedVersion { _ = try ReleaseVersion(dismissed) }
            for date in [state.lastCheckedAt, state.nextCheckAt, state.retryNotBefore].compactMap({ $0 }) {
                guard date.timeIntervalSince1970.isFinite else { throw UpdateCheckError.invalidCache }
            }
            guard state.lastCheckedAt.map({ $0 <= clock() }) != false else { throw UpdateCheckError.invalidCache }
            saved = state
        } catch {
            defaults.removeObject(forKey: Self.settingsKey)
            errorMessage = UpdateCheckError.invalidCache.localizedDescription
            diagnostics.logFailure(.updateCacheInvalidated, error: error, operation: .appUpdates)
            logger.warning("Saved update information was invalid and has been cleared.")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(saved)
            guard data.count <= Self.maximumCacheBytes else { throw UpdateCheckError.invalidCache }
            defaults.set(data, forKey: Self.settingsKey)
        } catch {
            errorMessage = "Update information could not be saved. Check ReviewQ Diagnostics."
            diagnostics.logFailure(.updateCacheWriteFailed, error: error, operation: .appUpdates)
            logger.warning("Update information could not be saved.")
        }
    }

    private struct SavedState: Codable {
        var schema = 1
        var release: AvailableUpdate?
        var entityTag: String?
        var lastCheckedAt: Date?
        var nextCheckAt: Date?
        var retryNotBefore: Date?
        var dismissedVersion: String?
        var failureCount = 0
    }
}
