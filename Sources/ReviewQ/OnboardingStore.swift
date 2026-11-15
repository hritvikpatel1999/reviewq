import AppKit
import ApplicationServices
import Combine
import ReviewQCore

enum OnboardingStep: Int, CaseIterable, Codable {
    case welcome, sources, authentication, companions, preferences, ready

    var title: String {
        switch self {
        case .welcome: "Your reviews. One quiet home."
        case .sources: "Where do you review?"
        case .authentication: "Connect Azure DevOps"
        case .companions: "Your review companions"
        case .preferences: "Make it yours"
        case .ready: "You're ready"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "The pull requests that need you, right in your menu bar."
        case .sources: "Add the organizations or projects you want in your queue."
        case .authentication: "Use your Azure CLI sign-in or a read-only personal access token."
        case .companions: "Optional shortcuts. Your browser is always enough to get started."
        case .preferences: "Start simple. You can change everything later in Settings."
        case .ready: "Your first queue is loaded. ReviewQ will take it from here."
        }
    }
}

struct ReviewCompanionStatus: Equatable {
    var copilotInstalled: Bool
    var scoutInstalled: Bool
    var edgeInstalled: Bool
    var scoutAccessibilityAllowed: Bool

    @MainActor
    static func current() -> Self {
        Self(
            copilotInstalled: ReviewAssistant.copilot.applicationURL != nil,
            scoutInstalled: ReviewAssistant.scout.applicationURL != nil,
            edgeInstalled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac") != nil,
            scoutAccessibilityAllowed: AXIsProcessTrusted()
        )
    }
}

@MainActor
final class OnboardingStore: ObservableObject {
    typealias ConnectionCheck = @MainActor (ReviewConfiguration, String) async throws -> ReviewSnapshot
    static let progressKey = "reviewOnboardingProgress"
    static let completedKey = "reviewOnboardingCompleted"
    static let loginCommand = "az login --allow-no-subscriptions"

    @Published var draft: ReviewConfiguration {
        didSet {
            guard draft != oldValue else { return }
            if AccountInput(draft) != AccountInput(oldValue) {
                invalidateConnection()
            } else if ConnectionInput(draft) != ConnectionInput(oldValue) {
                invalidateConnection(preserveAccount: true)
            }
            errorMessage = nil
            persistProgress()
        }
    }
    @Published var token = "" {
        didSet {
            if token != oldValue { invalidateConnection(); errorMessage = nil }
        }
    }
    @Published private(set) var step: OnboardingStep = .welcome {
        didSet { persistProgress() }
    }
    @Published private(set) var snapshot: ReviewSnapshot?
    @Published private(set) var isChecking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var infoMessage: String?
    @Published private(set) var companions: ReviewCompanionStatus
    private(set) var isActive = false
    private let store: ReviewStore
    private let defaults: UserDefaults
    private let diagnostics: DiagnosticLogger
    private let checkConnection: ConnectionCheck
    private let companionStatus: @MainActor () -> ReviewCompanionStatus
    private var verifiedInput: ConnectionInput?
    private var verifiedAccount: AccountInput?
    private var checkTask: Task<ReviewSnapshot, Error>?
    private var generation = UUID()

    init(
        store: ReviewStore, defaults: UserDefaults = .standard, diagnostics: DiagnosticLogger = .disabled,
        keychain: any PATStoring = KeychainPATStore(), checkConnection: ConnectionCheck? = nil,
        companionStatus: @escaping @MainActor () -> ReviewCompanionStatus = ReviewCompanionStatus.current
    ) {
        self.store = store
        self.defaults = defaults
        self.diagnostics = diagnostics
        self.companionStatus = companionStatus
        companions = companionStatus()
        draft = store.configuration
        self.checkConnection = checkConnection ?? { configuration, token in
            let credentials = SetupPATStore(token: token, saved: keychain)
            return try await AzureDevOpsReviewLoader(
                keychain: credentials, diagnostics: diagnostics, defaults: defaults
            ).load(configuration: configuration)
        }
        if defaults.object(forKey: Self.progressKey) != nil {
            do {
                guard let data = defaults.data(forKey: Self.progressKey) else { throw SetupError.corruptProgress }
                let progress = try JSONDecoder().decode(Progress.self, from: data)
                draft = progress.configuration
                step = progress.step.rawValue > OnboardingStep.authentication.rawValue ? .authentication : progress.step
                isActive = true
                infoMessage = "Your setup choices were restored. Test your connection again; unsaved PATs must be entered again."
            } catch {
                errorMessage = SetupError.corruptProgress.localizedDescription
                diagnostics.log(.warning, .settingsFailed, operation: .settings, reason: .corruptSettings)
            }
        }
    }

    var shouldPresentAutomatically: Bool {
        isActive || (!defaults.bool(forKey: Self.completedKey) && !store.configuration.hasSources && store.errorMessage == nil)
    }

    var hasVerifiedConnection: Bool { snapshot != nil && verifiedInput == ConnectionInput(draft) }
    var hasVerifiedAccount: Bool { verifiedAccount == AccountInput(draft) }
    var canKeepExistingSettings: Bool { store.configuration.hasSources }

    var canContinue: Bool {
        !isChecking && (step != .authentication || hasVerifiedAccount)
    }

    var primaryButtonTitle: String {
        switch step {
        case .welcome: "Get started"
        case .ready: "Open my queue"
        case .preferences where !hasVerifiedConnection: "Check and continue"
        default: "Continue"
        }
    }

    func begin() {
        if !isActive {
            draft = store.configuration
            step = .welcome
            infoMessage = nil
            invalidateConnection()
        }
        if step.rawValue >= OnboardingStep.companions.rawValue, !hasVerifiedAccount {
            step = .authentication
            infoMessage = "Your setup choices are still here. Test your connection again to continue."
        }
        isActive = true
        persistProgress()
        refreshCompanions()
    }

    func back() {
        guard !isChecking, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        errorMessage = nil
        infoMessage = nil
        step = previous
    }

    func advance() async {
        guard !isChecking else { return }
        do {
            switch step {
            case .welcome: step = .sources
            case .sources:
                _ = try draft.validatedSourceURLs()
                step = .authentication
            case .authentication:
                guard hasVerifiedAccount else { throw SetupError.connectionRequired }
                step = .companions
                refreshCompanions()
            case .companions: step = .preferences
            case .preferences:
                _ = try draft.validatedSources()
                if !hasVerifiedConnection { await testConnection() }
                guard hasVerifiedConnection else { return }
                step = .ready
            case .ready: return
            }
            errorMessage = nil
            infoMessage = nil
        } catch { report(error, event: .settingsFailed) }
    }

    func testConnection() async {
        guard !isChecking else { return }
        errorMessage = nil
        infoMessage = nil
        var configuration = draft
        if step == .authentication {
            configuration.followPeople = false
            configuration.showAuthoredPullRequests = false
        }
        do {
            _ = try configuration.validatedSources()
            if configuration.authentication == .personalAccessToken, !token.isEmpty {
                _ = try KeychainPATStore.validate(token)
            }
        } catch {
            report(error, event: .settingsFailed)
            return
        }
        let newPAT = token
        let currentGeneration = generation
        let cycleID = UUID()
        isChecking = true
        let task = Task {
            try await DiagnosticContext.$cycleID.withValue(cycleID) {
                try Task.checkCancellation()
                return try await checkConnection(configuration, newPAT)
            }
        }
        checkTask = task
        diagnostics.log(.info, .refreshStarted, operation: .reviews, cycleID: cycleID)
        defer {
            if generation == currentGeneration { isChecking = false; checkTask = nil }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled, !task.isCancelled, generation == currentGeneration else { return }
            snapshot = result
            verifiedInput = ConnectionInput(configuration)
            verifiedAccount = AccountInput(configuration)
            diagnostics.log(.info, .refreshFinished, operation: .reviews, cycleID: cycleID, count: result.pullRequests.count)
        } catch is CancellationError {
            diagnostics.log(.info, .refreshCancelled, operation: .reviews, cycleID: cycleID, reason: .cancelled)
        } catch {
            guard generation == currentGeneration, !Task.isCancelled, !task.isCancelled else { return }
            snapshot = nil
            verifiedInput = nil
            verifiedAccount = nil
            report(error, event: .refreshFailed)
        }
    }

    func complete() -> Bool {
        do {
            guard step == .ready, hasVerifiedConnection, let snapshot else { throw SetupError.connectionRequired }
            try store.save(draft, newPAT: token, verifiedSnapshot: snapshot)
            defaults.set(true, forKey: Self.completedKey)
            isActive = false
            defaults.removeObject(forKey: Self.progressKey)
            token = ""
            errorMessage = nil
            return true
        } catch {
            report(error, event: .settingsFailed)
            return false
        }
    }

    func pause() {
        invalidateConnection()
        token = ""
    }

    func keepExistingSettings() {
        pause()
        isActive = false
        defaults.removeObject(forKey: Self.progressKey)
        draft = store.configuration
        step = .welcome
        errorMessage = nil
        infoMessage = nil
    }

    func refreshCompanions() { companions = companionStatus() }

    func reportActionError(_ message: String) {
        errorMessage = message
        diagnostics.log(.warning, .applicationActionFailed, operation: .application, reason: .system)
    }

    private func invalidateConnection(preserveAccount: Bool = false) {
        generation = UUID()
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        snapshot = nil
        verifiedInput = nil
        if !preserveAccount { verifiedAccount = nil }
    }

    private func persistProgress() {
        guard isActive else { return }
        do {
            defaults.set(try JSONEncoder().encode(Progress(step: step, configuration: draft)), forKey: Self.progressKey)
        } catch { report(error, event: .settingsFailed) }
    }

    private func report(_ error: any Error, event: DiagnosticEvent) {
        errorMessage = error.localizedDescription
        diagnostics.logFailure(event, error: error, operation: event == .refreshFailed ? .reviews : .settings)
    }

    private struct Progress: Codable {
        let step: OnboardingStep
        let configuration: ReviewConfiguration
    }

    private struct AccountInput: Equatable {
        let sources: String
        let authentication: AuthenticationMethod
        let tenant: String

        init(_ configuration: ReviewConfiguration) {
            sources = configuration.sourceURLs
            authentication = configuration.authentication
            tenant = configuration.tenantID
        }
    }

    private struct ConnectionInput: Equatable {
        let sources: String
        let authentication: AuthenticationMethod
        let tenant: String
        let drafts: Bool
        let follows: Bool
        let emails: String
        let authored: Bool

        init(_ configuration: ReviewConfiguration) {
            sources = configuration.sourceURLs
            authentication = configuration.authentication
            tenant = configuration.tenantID
            drafts = configuration.includeDrafts
            follows = configuration.followPeople
            emails = configuration.followedAuthorEmails
            authored = configuration.showAuthoredPullRequests
        }
    }
}

enum SetupError: LocalizedError {
    case corruptProgress, connectionRequired

    var errorDescription: String? {
        switch self {
        case .corruptProgress: "Saved setup progress could not be read. Check your choices before continuing. Saved Settings were not changed."
        case .connectionRequired: "Test your current connection successfully before finishing setup."
        }
    }
}

struct SetupPATStore: PATStoring {
    let token: String
    let saved: any PATStoring

    func load() throws -> String? {
        token.isEmpty ? try saved.load() : try KeychainPATStore.validate(token)
    }

    func save(_ token: String) throws { throw CocoaError(.featureUnsupported) }
    func remove() throws { throw CocoaError(.featureUnsupported) }
}
