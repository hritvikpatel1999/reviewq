import Foundation
@testable import ReviewQ
@testable import ReviewQCore
import XCTest

@MainActor
final class OnboardingTests: XCTestCase {
    func testFreshSetupRequiresVerifiedAccessAndReusesTheQueueWithoutAnImmediateRefetch() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.shouldPresentAutomatically)
        fixture.store.start()
        await fixture.reach(.authentication)
        XCTAssertFalse(fixture.model.canContinue)
        XCTAssertFalse(fixture.model.complete())
        XCTAssertNotNil(fixture.model.errorMessage)
        await fixture.model.testConnection()
        XCTAssertTrue(fixture.model.hasVerifiedConnection)
        XCTAssertNil(fixture.store.snapshot)
        XCTAssertNil(fixture.defaults.data(forKey: ReviewStore.settingsKey))
        await fixture.model.advance()
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .preferences)
        fixture.model.draft.showCount = false
        fixture.model.draft.refreshInterval = .thirtyMinutes
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .ready)
        XCTAssertEqual(fixture.checks.configurations.count, 1, "Local display preferences need no new connection test.")
        XCTAssertTrue(fixture.model.complete())
        XCTAssertEqual(fixture.store.snapshot?.pendingReviewCount, 0, "A successful empty queue is a valid result.")
        XCTAssertFalse(fixture.store.changes.hasChanges)
        XCTAssertEqual(fixture.store.configuration.refreshInterval, .thirtyMinutes)
        XCTAssertFalse(fixture.store.configuration.showCount)
        XCTAssertTrue(fixture.defaults.bool(forKey: OnboardingStore.completedKey))
        XCTAssertNil(fixture.defaults.object(forKey: OnboardingStore.progressKey))
        try await Task.sleep(for: .milliseconds(20))
        let calls = await fixture.loader.calls
        XCTAssertEqual(calls, 0, "Finishing setup must not immediately repeat the verified refresh.")
        await fixture.store.refresh()
        let refreshedCalls = await fixture.loader.calls
        XCTAssertEqual(refreshedCalls, 1, "Normal refresh remains usable after setup.")
    }

    func testResumeRetainsChoicesButNeverPersistsPATOrTreatsAnOldConnectionAsVerified() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        await fixture.reach(.authentication)
        fixture.model.draft.authentication = .personalAccessToken
        fixture.model.token = "SYNTHETIC_SETUP_PAT_NOT_A_CREDENTIAL"
        await fixture.model.testConnection()
        await fixture.model.advance()
        await fixture.model.advance()
        fixture.model.draft.showCount = false
        let data = try XCTUnwrap(fixture.defaults.data(forKey: OnboardingStore.progressKey))
        XCTAssertNil(data.range(of: Data(fixture.model.token.utf8)))
        XCTAssertNil(fixture.defaults.data(forKey: ReviewStore.settingsKey))
        XCTAssertEqual(fixture.keychain.savedTokens, [])
        fixture.model.pause()
        let resumed = fixture.newModel()
        XCTAssertTrue(resumed.shouldPresentAutomatically)
        XCTAssertEqual(resumed.step, .authentication)
        XCTAssertEqual(resumed.draft.sourceURLs, fixture.model.draft.sourceURLs)
        XCTAssertEqual(resumed.draft.authentication, .personalAccessToken)
        XCTAssertFalse(resumed.draft.showCount)
        XCTAssertTrue(resumed.token.isEmpty)
        XCTAssertFalse(resumed.hasVerifiedConnection)
        XCTAssertNotNil(resumed.infoMessage)
    }

    func testFinishingAfterTheVerifiedQueueHasExpiredTriggersANormalRefresh() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        fixture.checks.snapshot = ReviewSnapshot(pullRequests: [], updatedAt: .distantPast)
        fixture.store.start()
        await fixture.reach(.ready)
        XCTAssertTrue(fixture.model.complete())
        await fixture.loader.waitUntilLoaded()
        let calls = await fixture.loader.calls
        XCTAssertEqual(calls, 1, "An old setup result must not postpone fresh data for another polling interval.")
    }

    func testQueueOptionsAreValidatedAndRecheckedBeforeReadyWithoutAddingCompanionRequests() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        await fixture.reach(.preferences)
        XCTAssertEqual(fixture.checks.configurations.count, 1)
        XCTAssertFalse(fixture.model.draft.followPeople)
        XCTAssertFalse(fixture.model.draft.showAuthoredPullRequests)
        fixture.model.draft.followPeople = true
        fixture.model.draft.followedAuthorEmails = "invalid"
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .preferences)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.checks.configurations.count, 1)
        fixture.model.draft.followedAuthorEmails = "alex@example.com;sam@example.com"
        fixture.model.draft.showAuthoredPullRequests = true
        fixture.model.draft.includeDrafts = true
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .ready)
        XCTAssertEqual(fixture.checks.configurations.count, 2)
        XCTAssertTrue(try XCTUnwrap(fixture.checks.configurations.last).showAuthoredPullRequests)
        XCTAssertTrue(fixture.model.hasVerifiedConnection)
    }

    func testExistingConfiguredUsersAreNotOnboardedAndAbandonedReplayCannotOverwriteSettings() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var saved = ReviewConfiguration()
        saved.sourceURLs = "https://dev.azure.com/existing/Project"
        saved.refreshInterval = .fiveMinutes
        saved.scoutAdditionalInstructions = "Keep the existing workflow."
        saved.showAuthoredPullRequests = true
        let snapshot = ReviewSnapshot(pullRequests: [])
        try fixture.store.save(saved, verifiedSnapshot: snapshot)
        let original = fixture.defaults.data(forKey: ReviewStore.settingsKey)
        let model = fixture.newModel()
        XCTAssertFalse(model.shouldPresentAutomatically)
        XCTAssertEqual(model.draft, saved)
        model.begin()
        model.draft.sourceURLs = "https://dev.azure.com/another/Project"
        model.token = "SYNTHETIC_UNSAVED_REPLACEMENT"
        model.pause()
        XCTAssertEqual(fixture.defaults.data(forKey: ReviewStore.settingsKey), original)
        XCTAssertEqual(fixture.store.snapshot, snapshot)
        XCTAssertEqual(fixture.keychain.savedTokens, [])
        XCTAssertTrue(fixture.newModel().shouldPresentAutomatically, "An explicitly started replay resumes after being closed.")
    }

    func testSourceValidationDoesNotTrapUsersBehindLaterOptionalEmailErrors() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        fixture.model.begin()
        await fixture.model.advance()
        fixture.model.draft.sourceURLs = "http://dev.azure.com/example/Project"
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .sources)
        XCTAssertNotNil(fixture.model.errorMessage)
        fixture.model.draft.sourceURLs = "https://dev.azure.com/example/Project"
        fixture.model.draft.followPeople = true
        fixture.model.draft.followedAuthorEmails = "invalid"
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .authentication)
        await fixture.model.testConnection()
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.checks.configurations.count, 1)
        XCTAssertTrue(fixture.model.hasVerifiedAccount)
        XCTAssertFalse(fixture.model.hasVerifiedConnection)
        await fixture.model.advance()
        await fixture.model.advance()
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .preferences)
        XCTAssertNotNil(fixture.model.errorMessage)
    }

    func testReplayUsesTheLatestSavedPreferencesAndCanKeepThemWithoutReconnecting() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var saved = ReviewConfiguration()
        saved.sourceURLs = "https://dev.azure.com/current/Project"
        saved.copilotAdditionalInstructions = "Keep this newly saved instruction."
        saved.refreshInterval = .fiveMinutes
        try fixture.store.save(saved)
        fixture.model.begin()
        XCTAssertEqual(fixture.model.draft, saved, "A long-running app must not reuse its launch-time configuration.")
        let persisted = fixture.defaults.data(forKey: ReviewStore.settingsKey)
        fixture.model.draft.sourceURLs = "https://dev.azure.com/abandoned/Project"
        fixture.model.token = "SYNTHETIC_ABANDONED_SETUP_PAT"
        fixture.model.keepExistingSettings()
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertNil(fixture.defaults.object(forKey: OnboardingStore.progressKey))
        XCTAssertEqual(fixture.defaults.data(forKey: ReviewStore.settingsKey), persisted)
        XCTAssertEqual(fixture.model.draft, saved)
        XCTAssertTrue(fixture.model.token.isEmpty)
        XCTAssertTrue(fixture.checks.configurations.isEmpty)
    }

    func testConnectionFailureCannotAppearReadyOrReplaceTheSavedQueue() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        await fixture.reach(.authentication)
        fixture.checks.error = .http(403, "example/Project")
        await fixture.model.testConnection()
        XCTAssertFalse(fixture.model.hasVerifiedConnection)
        XCTAssertFalse(fixture.model.canContinue)
        XCTAssertNotNil(fixture.model.errorMessage)
        await fixture.model.advance()
        XCTAssertEqual(fixture.model.step, .authentication)
        XCTAssertFalse(fixture.model.complete())
        XCTAssertNil(fixture.defaults.data(forKey: ReviewStore.settingsKey))
        XCTAssertFalse(fixture.defaults.bool(forKey: OnboardingStore.completedKey))
    }

    func testClosingOrEditingDuringACheckRejectsLateResultsAndClearsTheToken() async throws {
        for closeWindow in [true, false] {
            let deferred = DeferredSetupConnection()
            let fixture = try OnboardingFixture(checkConnection: { configuration, _ in
                try await deferred.check(configuration)
            })
            defer { fixture.close() }
            await fixture.reach(.authentication)
            fixture.model.token = "SYNTHETIC_TEMPORARY_PAT"
            let check = Task { await fixture.model.testConnection() }
            await deferred.waitUntilStarted()
            XCTAssertTrue(fixture.model.isChecking)
            if closeWindow {
                fixture.model.pause()
                XCTAssertTrue(fixture.model.token.isEmpty)
            } else {
                fixture.model.draft.sourceURLs = "https://dev.azure.com/new/Project"
            }
            await deferred.finish()
            await check.value
            XCTAssertFalse(fixture.model.hasVerifiedConnection)
            XCTAssertFalse(fixture.model.isChecking)
            XCTAssertNil(fixture.model.snapshot)
            XCTAssertNil(fixture.store.snapshot)
        }
    }

    func testKeychainFailureKeepsSetupIncompleteAndThePATOutOfPreferencesUntilRetry() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        await fixture.reach(.authentication)
        fixture.model.draft.authentication = .personalAccessToken
        fixture.model.token = "SYNTHETIC_PAT_FOR_KEYCHAIN_ONLY"
        await fixture.model.testConnection()
        await fixture.reach(.ready)
        fixture.keychain.saveError = .keychain(-25293)
        XCTAssertFalse(fixture.model.complete())
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertFalse(fixture.defaults.bool(forKey: OnboardingStore.completedKey))
        XCTAssertNil(fixture.defaults.data(forKey: ReviewStore.settingsKey))
        XCTAssertNotNil(fixture.defaults.data(forKey: OnboardingStore.progressKey))
        fixture.keychain.saveError = nil
        XCTAssertTrue(fixture.model.complete())
        XCTAssertEqual(fixture.keychain.savedTokens, ["SYNTHETIC_PAT_FOR_KEYCHAIN_ONLY"])
        XCTAssertTrue(fixture.model.token.isEmpty)
        let persisted = try XCTUnwrap(fixture.defaults.data(forKey: ReviewStore.settingsKey))
        XCTAssertNil(persisted.range(of: Data("SYNTHETIC_PAT_FOR_KEYCHAIN_ONLY".utf8)))
        XCTAssertFalse(fixture.newModel().shouldPresentAutomatically)
    }

    func testCorruptProgressIsVisibleWithoutDiscardingPreviouslySavedSettings() throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var configuration = ReviewConfiguration()
        configuration.sourceURLs = "https://dev.azure.com/existing/Project"
        try fixture.store.save(configuration)
        fixture.defaults.set(Data("invalid-setup-state".utf8), forKey: OnboardingStore.progressKey)
        let model = fixture.newModel()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.draft, configuration)
        XCTAssertFalse(model.shouldPresentAutomatically)
        XCTAssertEqual(fixture.store.configuration, configuration)
    }

    func testSetupCredentialsUseNewOrExistingPATReadOnlyDuringConnectionChecks() throws {
        let keychain = SetupTestPATStore()
        try keychain.save("synthetic-existing-pat")
        let existing = SetupPATStore(token: "", saved: keychain)
        XCTAssertEqual(try existing.load(), "synthetic-existing-pat")
        let replacement = SetupPATStore(token: "synthetic-new-pat", saved: keychain)
        XCTAssertEqual(try replacement.load(), "synthetic-new-pat")
        XCTAssertThrowsError(try replacement.save("must-not-write"))
        XCTAssertThrowsError(try replacement.remove())
        XCTAssertEqual(try keychain.load(), "synthetic-existing-pat")
    }
}

@MainActor
final class OnboardingFixture {
    let suite = "ReviewQ-setup-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let keychain = SetupTestPATStore()
    let loader = SetupReviewLoader()
    let checks = SetupConnectionSpy()
    let store: ReviewStore
    let model: OnboardingStore

    init(checkConnection: OnboardingStore.ConnectionCheck? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = ReviewStore(defaults: defaults, keychain: keychain, loader: loader)
        let checks = checks
        model = OnboardingStore(
            store: store, defaults: defaults, keychain: keychain,
            checkConnection: checkConnection ?? { configuration, token in try await checks.check(configuration, token) },
            companionStatus: Self.companions
        )
    }

    static func companions() -> ReviewCompanionStatus {
        ReviewCompanionStatus(
            copilotInstalled: true, scoutInstalled: true, edgeInstalled: false, scoutAccessibilityAllowed: false
        )
    }

    func newModel() -> OnboardingStore {
        OnboardingStore(
            store: store, defaults: defaults, keychain: keychain,
            checkConnection: { [checks] configuration, token in try await checks.check(configuration, token) },
            companionStatus: Self.companions
        )
    }

    func reach(_ step: OnboardingStep) async {
        model.begin()
        while model.step.rawValue < step.rawValue {
            let previous = model.step
            if previous == .sources, model.draft.sourceURLs.isEmpty {
                model.draft.sourceURLs = "https://dev.azure.com/example/Project"
            }
            if previous == .authentication, !model.hasVerifiedConnection { await model.testConnection() }
            await model.advance()
            if model.step == previous {
                XCTFail("Could not reach setup step \(step): \(model.errorMessage ?? "missing validation result")")
                return
            }
        }
    }

    func close() {
        model.pause()
        store.stop()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class SetupConnectionSpy {
    var configurations: [ReviewConfiguration] = []
    var error: ReviewQError?
    var snapshot = ReviewSnapshot(pullRequests: [])

    func check(_ configuration: ReviewConfiguration, _ token: String) async throws -> ReviewSnapshot {
        configurations.append(configuration)
        if let error { throw error }
        return snapshot
    }
}

actor SetupReviewLoader: ReviewLoading {
    private(set) var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func invalidateIdentityCache() {}
    func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
        calls += 1
        waiter?.resume()
        waiter = nil
        return ReviewSnapshot(pullRequests: [])
    }
    func waitUntilLoaded() async {
        if calls > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

final class SetupTestPATStore: PATStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    private var failure: ReviewQError?
    var savedTokens: [String] { lock.withLock { tokens } }
    var saveError: ReviewQError? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    func load() throws -> String? { lock.withLock { tokens.last } }
    func save(_ token: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            tokens.append(token)
        }
    }
    func remove() throws { lock.withLock { tokens.removeAll() } }
}

private actor DeferredSetupConnection {
    private var continuation: CheckedContinuation<ReviewSnapshot, Error>?
    func check(_ configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish() {
        continuation?.resume(returning: ReviewSnapshot(pullRequests: []))
        continuation = nil
    }
}
