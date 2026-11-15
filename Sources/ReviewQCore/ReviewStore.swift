import Combine
import Foundation
import OSLog

@MainActor
public final class ReviewStore: ObservableObject {
    @Published public private(set) var configuration: ReviewConfiguration
    @Published public private(set) var snapshot: ReviewSnapshot?
    @Published public private(set) var changes = ReviewChanges()
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var errorMessage: String?

    public static let settingsKey = "reviewConfiguration"
    private let loader: any ReviewLoading
    private let keychain: any PATStoring
    private let defaults: UserDefaults
    private let diagnostics: DiagnosticLogger
    private let queueCache: ReviewQueueCache
    private let logger = Logger(subsystem: "dev.prbar.app", category: "reviews")
    private var pollingTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var generation = UUID()
    private var isStarted = false

    public init(
        defaults: UserDefaults = .standard,
        keychain: any PATStoring = KeychainPATStore(),
        loader: (any ReviewLoading)? = nil,
        diagnostics: DiagnosticLogger = .disabled
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.diagnostics = diagnostics
        queueCache = ReviewQueueCache(defaults: defaults, diagnostics: diagnostics)
        self.loader = loader ?? AzureDevOpsReviewLoader(
            keychain: keychain, diagnostics: diagnostics, defaults: defaults
        )
        var loaded = ReviewConfiguration()
        var initialError: String?
        var initialReason: DiagnosticReason = .corruptSettings
        if let data = defaults.data(forKey: Self.settingsKey) {
            do {
                loaded = try JSONDecoder().decode(ReviewConfiguration.self, from: data)
                try loaded.validatedReviewPrompts()
                _ = try loaded.validatedFollowedAuthors()
                if loaded.hasSources { _ = try loaded.validatedSources() }
            } catch {
                initialError = error is DecodingError
                    ? ReviewQError.corruptSettings.localizedDescription : error.localizedDescription
                initialReason = error is DecodingError ? .corruptSettings : .invalidConfiguration
            }
        } else if defaults.object(forKey: Self.settingsKey) != nil {
            initialError = ReviewQError.corruptSettings.localizedDescription
        }
        configuration = loaded
        errorMessage = initialError
        if initialError != nil {
            logger.error("Saved review settings are invalid. Check Settings.")
            diagnostics.log(.warning, .settingsFailed, operation: .settings, reason: initialReason)
        }
    }

    public var menuBarTitle: String {
        if errorMessage != nil {
            if configuration.showCount, let snapshot { return " \(snapshot.pendingReviewCount) !" }
            return " !"
        }
        guard configuration.hasSources else { return "" }
        guard let snapshot else { return " ..." }
        return configuration.showCount ? " \(snapshot.pendingReviewCount)" : ""
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        startPolling()
    }

    public func stop() {
        isStarted = false
        cancelTasks()
    }

    public func requestRefresh() {
        guard !isRefreshing else { return }
        manualTask?.cancel()
        manualTask = Task { [weak self] in await self?.refresh() }
    }

    public func refreshIdentities() async {
        cancelTasks()
        let currentGeneration = generation
        await loader.invalidateIdentityCache()
        guard generation == currentGeneration else {
            diagnostics.log(.info, .refreshCancelled, operation: .identityCache, reason: .superseded)
            return
        }
        if isStarted {
            startPolling()
        } else {
            await refresh()
        }
    }

    public func refresh() async {
        guard configuration.hasSources, !isRefreshing else { return }
        let currentGeneration = generation
        let currentConfiguration = configuration
        let cycleID = UUID()
        let started = ContinuousClock.now
        diagnostics.log(
            .info, .refreshStarted, operation: .reviews, cycleID: cycleID,
            count: currentConfiguration.sourceURLs.split(whereSeparator: \.isNewline).count
        )
        isRefreshing = true
        defer {
            if generation == currentGeneration { isRefreshing = false }
        }
        do {
            let result = try await DiagnosticContext.$cycleID.withValue(cycleID) {
                try await loader.load(configuration: currentConfiguration, onIdentityScope: { [weak self] scope in
                    await self?.restoreCachedQueue(
                        identityScope: scope, configuration: currentConfiguration, generation: currentGeneration
                    )
                })
            }
            guard !Task.isCancelled, generation == currentGeneration else {
                diagnostics.log(
                    .info, .refreshCancelled, operation: .reviews, cycleID: cycleID,
                    reason: Task.isCancelled ? .cancelled : .superseded,
                    durationMilliseconds: DiagnosticTiming.milliseconds(since: started)
                )
                return
            }
            changes = ReviewChanges(previous: snapshot, current: result)
            snapshot = result
            errorMessage = nil
            if result.identityScope != nil { queueCache.save(result, configuration: currentConfiguration) }
            diagnostics.log(
                .info, .refreshFinished, operation: .reviews, cycleID: cycleID,
                durationMilliseconds: DiagnosticTiming.milliseconds(since: started),
                count: result.pullRequests.count
            )
            logger.notice("Review refresh succeeded: \(result.pullRequests.count, privacy: .public) pull requests.")
        } catch is CancellationError {
            diagnostics.log(
                .info, .refreshCancelled, operation: .reviews, cycleID: cycleID,
                reason: .cancelled, durationMilliseconds: DiagnosticTiming.milliseconds(since: started)
            )
            return
        } catch {
            guard !Task.isCancelled, generation == currentGeneration else {
                diagnostics.log(
                    .info, .refreshCancelled, operation: .reviews, cycleID: cycleID, reason: .superseded,
                    durationMilliseconds: DiagnosticTiming.milliseconds(since: started)
                )
                return
            }
            errorMessage = error.localizedDescription
            diagnostics.logFailure(.refreshFailed, error: error, operation: .reviews, cycleID: cycleID)
            logger.error("Review refresh failed. Open ReviewQ Diagnostics for the safe failure category.")
        }
    }

    private func restoreCachedQueue(
        identityScope: String, configuration: ReviewConfiguration, generation: UUID
    ) {
        guard !Task.isCancelled, self.generation == generation else { return }
        if let snapshot, snapshot.identityScope != identityScope {
            self.snapshot = nil
            changes = ReviewChanges()
            queueCache.clear()
        }
        if snapshot == nil {
            snapshot = queueCache.load(configuration: configuration, identityScope: identityScope)
        }
    }

    public func save(
        _ configuration: ReviewConfiguration, newPAT: String = "", verifiedSnapshot: ReviewSnapshot? = nil
    ) throws {
        do {
            try saveSettings(configuration, newPAT: newPAT, verifiedSnapshot: verifiedSnapshot)
            diagnostics.log(.info, .settingsSaved, operation: .settings)
        } catch {
            diagnostics.logFailure(.settingsFailed, error: error, operation: .settings)
            throw error
        }
    }

    private func saveSettings(
        _ configuration: ReviewConfiguration, newPAT: String, verifiedSnapshot: ReviewSnapshot?
    ) throws {
        _ = try configuration.validatedSources()
        let data = try JSONEncoder().encode(configuration)
        if configuration.authentication == .personalAccessToken {
            if !newPAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.save(KeychainPATStore.validate(newPAT))
            } else {
                guard let token = try keychain.load() else { throw ReviewQError.missingPAT }
                _ = try KeychainPATStore.validate(token)
            }
        }
        defaults.set(data, forKey: Self.settingsKey)
        cancelTasks()
        self.configuration = configuration
        queueCache.clear()
        snapshot = verifiedSnapshot
        if let verifiedSnapshot, verifiedSnapshot.identityScope != nil {
            queueCache.save(verifiedSnapshot, configuration: configuration)
        }
        changes = ReviewChanges()
        errorMessage = nil
        if isStarted {
            let needsRefresh = verifiedSnapshot.map {
                Date().timeIntervalSince($0.updatedAt) >= TimeInterval(configuration.refreshInterval.rawValue)
            } ?? true
            startPolling(refreshImmediately: needsRefresh)
        }
    }

    public func deleteSavedPAT() throws {
        do {
            try removeSavedPAT()
            diagnostics.log(.info, .patDeleted, operation: .settings)
        } catch {
            diagnostics.logFailure(.patDeleteFailed, error: error, operation: .settings)
            throw error
        }
    }

    private func removeSavedPAT() throws {
        try keychain.remove()
        if configuration.authentication == .personalAccessToken {
            cancelTasks()
            snapshot = nil
            changes = ReviewChanges()
            queueCache.clear()
            errorMessage = ReviewQError.missingPAT.localizedDescription
            if isStarted { startPolling() }
        }
    }

    private func cancelTasks() {
        generation = UUID()
        pollingTask?.cancel()
        manualTask?.cancel()
        pollingTask = nil
        manualTask = nil
        isRefreshing = false
    }

    private func startPolling(refreshImmediately: Bool = true) {
        pollingTask = Task { [weak self] in
            guard let self else { return }
            if refreshImmediately { await refresh() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(configuration.refreshInterval.rawValue))
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                    diagnostics.logFailure(.refreshFailed, error: error, operation: .reviews)
                    logger.error("Refresh scheduling failed. Check ReviewQ Diagnostics.")
                    return
                }
                await refresh()
            }
        }
    }
}
