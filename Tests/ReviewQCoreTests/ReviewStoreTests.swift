import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class ReviewStoreTests: XCTestCase {
    func testRelaunchDisplaysTheCachedQueueDuringLoadingAndRetainsItWhenRefreshFails() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var cached = ReviewSnapshot(pullRequests: [try cachedRequest(1)], updatedAt: .now.addingTimeInterval(-90))
        cached.identityScope = String(repeating: "a", count: 64)
        let first = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([.success(cached)]))
        try first.save(configuration())
        await first.refresh()
        first.stop()
        let stored = try XCTUnwrap(defaults.data(forKey: ReviewQueueCache.settingsKey))

        let loader = DeferredScopedReviewLoader(scope: try XCTUnwrap(cached.identityScope))
        let reopened = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        XCTAssertNil(reopened.snapshot, "A different account must not see a previous queue before its scope is checked.")
        let refresh = Task { await reopened.refresh() }
        await loader.waitUntilStarted()
        XCTAssertEqual(reopened.snapshot, cached)
        XCTAssertTrue(reopened.isRefreshing)
        XCTAssertEqual(reopened.menuBarTitle, " 1")
        XCTAssertFalse(reopened.changes.hasChanges)
        await loader.finish(.failure(.http(503, "example/Project")))
        await refresh.value
        XCTAssertEqual(reopened.snapshot, cached)
        XCTAssertNotNil(reopened.errorMessage)
        XCTAssertEqual(reopened.menuBarTitle, " 1 !")
        XCTAssertEqual(defaults.data(forKey: ReviewQueueCache.settingsKey), stored)
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
    }

    func testSuccessfulRefreshReplacesCachedBaselineIncludingAnEmptyQueue() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = String(repeating: "a", count: 64)
        var baseline = ReviewSnapshot(pullRequests: [try cachedRequest(1)])
        baseline.identityScope = scope
        let first = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([.success(baseline)]))
        try first.save(configuration())
        await first.refresh()

        let loader = DeferredScopedReviewLoader(scope: scope)
        let reopened = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        var next = ReviewSnapshot(pullRequests: [try cachedRequest(1, title: "Changed"), try cachedRequest(2)])
        next.identityScope = scope
        let refresh = Task { await reopened.refresh() }
        await loader.waitUntilStarted()
        await loader.finish(.success(next))
        await refresh.value
        XCTAssertEqual(reopened.changes.pullRequestIDs, Set(next.pullRequests.map(\.id)))
        XCTAssertEqual(ReviewQueueCache(defaults: defaults).load(configuration: configuration(), identityScope: scope), next)

        var empty = ReviewSnapshot(pullRequests: [])
        empty.identityScope = scope
        let emptyRefresh = Task { await reopened.refresh() }
        await loader.waitUntilStarted()
        await loader.finish(.success(empty))
        await emptyRefresh.value
        XCTAssertEqual(ReviewQueueCache(defaults: defaults).load(configuration: configuration(), identityScope: scope), empty)
        XCTAssertEqual(reopened.menuBarTitle, " 0")
    }

    func testChangedAccountAndCancelledOrSupersededResponsesCannotRestoreOrOverwriteTheCache() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = String(repeating: "a", count: 64)
        var baseline = ReviewSnapshot(pullRequests: [try cachedRequest(1)])
        baseline.identityScope = scope
        let cache = ReviewQueueCache(defaults: defaults)
        defaults.set(try JSONEncoder().encode(configuration()), forKey: ReviewStore.settingsKey)
        cache.save(baseline, configuration: configuration())
        let stored = defaults.data(forKey: ReviewQueueCache.settingsKey)
        let loader = DeferredScopedReviewLoader(scope: scope)
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        let cancelled = Task { await store.refresh() }
        await loader.waitUntilStarted()
        cancelled.cancel()
        var stale = ReviewSnapshot(pullRequests: [try cachedRequest(2)])
        stale.identityScope = scope
        await loader.finish(.success(stale))
        await cancelled.value
        XCTAssertEqual(store.snapshot, baseline)
        XCTAssertEqual(defaults.data(forKey: ReviewQueueCache.settingsKey), stored)

        let superseded = Task { await store.refresh() }
        await loader.waitUntilStarted()
        try store.save(configuration("https://dev.azure.com/another/Project"))
        await loader.finish(.success(stale))
        await superseded.value
        XCTAssertNil(store.snapshot)
        XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))

        defaults.set(try JSONEncoder().encode(configuration()), forKey: ReviewStore.settingsKey)
        cache.save(baseline, configuration: configuration())
        let otherLoader = DeferredScopedReviewLoader(scope: String(repeating: "b", count: 64))
        let other = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: otherLoader)
        let changedAccount = Task { await other.refresh() }
        await otherLoader.waitUntilStarted()
        XCTAssertNil(other.snapshot)
        XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
        await otherLoader.finish(.failure(.http(401, "example/Project")))
        await changedAccount.value
        XCTAssertNotNil(other.errorMessage)
    }

    func testVerifiedSetupSnapshotIsCachedAndDeletingItsPATRemovesIt() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var snapshot = ReviewSnapshot(pullRequests: [try cachedRequest(1)])
        snapshot.identityScope = String(repeating: "a", count: 64)
        var settings = configuration()
        settings.authentication = .personalAccessToken
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        try store.save(settings, verifiedSnapshot: snapshot)
        XCTAssertEqual(ReviewQueueCache(defaults: defaults).load(
            configuration: settings, identityScope: try XCTUnwrap(snapshot.identityScope)
        ), snapshot)
        try store.deleteSavedPAT()
        XCTAssertNil(store.snapshot)
        XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
    }

    private func cachedRequest(_ number: Int, title: String = "Original") throws -> ReviewPullRequest {
        var request = ReviewPullRequest(
            number: number, title: title, author: "Fixture author", organization: "example",
            project: "Project", repository: "Service", repositoryID: "service-id", createdAt: .distantPast,
            url: try AzureDevOpsURL.make(
                organization: "example", path: ["Project", "_git", "service-id", "pullrequest", String(number)]
            ),
            isRequired: true, isDraft: false, reviewStage: .commented,
            commentResolution: ReviewCommentResolution(resolvedCount: 2, openCount: 1)
        )
        request.changeFingerprint = Data(repeating: 1, count: 32)
        return request
    }

    func testDotsDescribeOnlyTheLatestSuccessfulRefreshAndIgnoreTimeAndOrdering() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try changeFixture(1)
        let second = try changeFixture(2)
        let edited = try changeFixture(1, title: "Edited")
        let loader = StubReviewLoader([
            .success(ReviewSnapshot(pullRequests: [first])),
            .success(ReviewSnapshot(pullRequests: [first, second])),
            .failure(.http(503, "example/Project")),
            .success(ReviewSnapshot(pullRequests: [second, edited])),
            .success(ReviewSnapshot(pullRequests: [edited, second], updatedAt: .distantFuture)),
            .success(ReviewSnapshot(pullRequests: [first]))
        ])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(configuration())
        await store.refresh()
        XCTAssertFalse(store.changes.hasChanges)
        await store.refresh()
        XCTAssertEqual(store.changes.pullRequestIDs, [second.id])
        await store.refresh()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.changes.pullRequestIDs, [second.id])
        await store.refresh()
        XCTAssertEqual(store.changes.pullRequestIDs, [edited.id], "Changes replace the previous dots instead of accumulating.")
        XCTAssertNil(store.errorMessage)
        await store.refresh()
        XCTAssertFalse(store.changes.hasChanges, "An unchanged refresh clears dots even when no PR was opened.")
        try store.save(configuration())
        await store.refresh()
        XCTAssertFalse(store.changes.hasChanges, "Saving Settings establishes a fresh baseline.")
        let calls = await loader.calls
        XCTAssertEqual(calls, 6)
    }

    private actor DeferredScopedReviewLoader: ReviewLoading {
        let scope: String
        private var pending: CheckedContinuation<ReviewSnapshot, any Error>?
        private var started: CheckedContinuation<Void, Never>?
        private(set) var calls = 0

        init(scope: String) { self.scope = scope }
        func invalidateIdentityCache() {}

        func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
            try await load(configuration: configuration, onIdentityScope: { _ in })
        }

        func load(
            configuration: ReviewConfiguration, onIdentityScope: @Sendable (String) async -> Void
        ) async throws -> ReviewSnapshot {
            calls += 1
            await onIdentityScope(scope)
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ result: Result<ReviewSnapshot, ReviewQError>) {
            pending?.resume(with: result.mapError { $0 as any Error })
            pending = nil
        }
    }

    func testCancelledRefreshDoesNotAdvanceTheDotBaseline() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let loader = DeferredReviewLoader()
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(configuration())
        let baseline = ReviewSnapshot(pullRequests: [try changeFixture(1)])
        let first = Task { await store.refresh() }
        await loader.waitUntilStarted()
        await loader.finish(baseline)
        await first.value
        let cancelled = Task { await store.refresh() }
        await loader.waitUntilStarted()
        cancelled.cancel()
        await loader.finish(ReviewSnapshot(pullRequests: [try changeFixture(2)]))
        await cancelled.value
        XCTAssertEqual(store.snapshot, baseline)
        XCTAssertFalse(store.changes.hasChanges)
        let next = Task { await store.refresh() }
        await loader.waitUntilStarted()
        await loader.finish(baseline)
        await next.value
        XCTAssertFalse(store.changes.hasChanges)
    }

    private func changeFixture(_ number: Int, title: String = "Original") throws -> ReviewPullRequest {
        ReviewPullRequest(
            number: number, title: title, author: "Fixture author", organization: "example",
            project: "Project", repository: "Service", repositoryID: "service-id", createdAt: .distantPast,
            url: try XCTUnwrap(URL(string: "https://dev.azure.com/example/Project/_git/repo/pullrequest/\(number)")),
            isRequired: false, isDraft: false, reviewStage: .firstReview
        )
    }

    func testRefreshingIdentitiesInvalidatesTheLoaderWithoutSavingSettingsOrDiscardingTheSnapshot() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let snapshot = ReviewSnapshot(pullRequests: [], updatedAt: Date(timeIntervalSince1970: 1))
        let loader = StubReviewLoader([.success(snapshot), .failure(.http(403, "example/Project"))])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        var saved = configuration()
        saved.refreshInterval = .fiveMinutes
        try store.save(saved)
        let encoded = defaults.data(forKey: ReviewStore.settingsKey)
        await store.refresh()
        await store.refreshIdentities()
        let invalidations = await loader.identityInvalidations
        let calls = await loader.calls
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.configuration, saved)
        XCTAssertEqual(defaults.data(forKey: ReviewStore.settingsKey), encoded)
    }

    private func preferences() throws -> (UserDefaults, String) {
        let name = "ReviewQ-tests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testFirstRunDoesNotFetchOrShowAnInventedZero() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let loader = StubReviewLoader([])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.menuBarTitle, "")
        let calls = await loader.calls
        XCTAssertEqual(calls, 0)
    }

    func testFailurePreservesLastSuccessfulSnapshotAndMarksCountStale() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let lastSuccess = ReviewSnapshot(pullRequests: [], updatedAt: Date(timeIntervalSince1970: 1))
        let loader = StubReviewLoader([.success(lastSuccess), .failure(.http(403, "example/Project"))])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(configuration())
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, " 0")
        await store.refresh()
        XCTAssertEqual(store.snapshot, lastSuccess)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.menuBarTitle, " 0 !")
    }

    func testFailureBeforeAnySuccessShowsErrorNotZero() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewStore(
            defaults: defaults, keychain: StubPATStore(),
            loader: StubReviewLoader([.failure(.http(401, "example/Project"))])
        )
        try store.save(configuration())
        await store.refresh()
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.menuBarTitle, " !")
    }

    func testSavingPreferencesPersistsConfigurationButNeverToken() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = configuration()
        settings.authentication = .personalAccessToken
        settings.includeDrafts = true
        settings.showCount = false
        settings.scoutAdditionalInstructions = "Use Scout's review skill.\nCheck correctness."
        settings.copilotAdditionalInstructions = "Use Copilot's review skill.\nCheck regressions."
        settings.followPeople = true
        settings.followedAuthorEmails = "alex@example.com;sam@example.com"
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        try store.save(settings, newPAT: "synthetic-token")
        let data = try XCTUnwrap(defaults.data(forKey: ReviewStore.settingsKey))
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("synthetic-token"))
        let restored = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        XCTAssertEqual(restored.configuration, settings)
    }

    func testInvalidPromptsCannotReplacePreferencesSnapshotOrPAT() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = StubPATStore(token: "original-token", onSave: { _ in
            XCTFail("Invalid prompts must be rejected before the saved PAT can be changed.")
        })
        let snapshot = ReviewSnapshot(pullRequests: [])
        let store = ReviewStore(defaults: defaults, keychain: keychain, loader: StubReviewLoader([.success(snapshot)]))
        var original = configuration()
        original.authentication = .personalAccessToken
        original.scoutAdditionalInstructions = "Original Scout instructions."
        original.copilotAdditionalInstructions = "Original Copilot instructions."
        try store.save(original)
        await store.refresh()
        let saved = try XCTUnwrap(defaults.data(forKey: ReviewStore.settingsKey))
        for assistant in 0..<2 {
            var invalid = original
            if assistant == 0 { invalid.scoutAdditionalInstructions = String(repeating: "x", count: 1_001) }
            else { invalid.copilotAdditionalInstructions = "Not allowed\tinput" }
            XCTAssertThrowsError(try store.save(invalid, newPAT: "replacement-token"))
            XCTAssertEqual(store.configuration, original)
            XCTAssertEqual(defaults.data(forKey: ReviewStore.settingsKey), saved)
            XCTAssertEqual(store.snapshot, snapshot)
            XCTAssertEqual(keychain.load(), "original-token")
        }
    }

    func testInvalidStoredPromptsAreVisibleEvenWithoutConfiguredSources() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = ReviewConfiguration()
        settings.copilotAdditionalInstructions = String(repeating: "x", count: 1_001)
        defaults.set(try JSONEncoder().encode(settings), forKey: ReviewStore.settingsKey)
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        XCTAssertEqual(store.errorMessage, ReviewQError.reviewPromptTooLong.localizedDescription)
        XCTAssertEqual(store.menuBarTitle, " !")
        XCTAssertEqual(store.configuration.copilotAdditionalInstructions, settings.copilotAdditionalInstructions)
    }

    func testInvalidFollowSettingsCannotReplacePreferencesSnapshotOrPAT() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = StubPATStore(onSave: { _ in
            XCTFail("Invalid followed emails must be rejected before the saved PAT can be changed.")
        })
        let snapshot = ReviewSnapshot(pullRequests: [])
        let store = ReviewStore(defaults: defaults, keychain: keychain, loader: StubReviewLoader([.success(snapshot)]))
        var original = configuration()
        original.authentication = .personalAccessToken
        try store.save(original)
        await store.refresh()
        let saved = try XCTUnwrap(defaults.data(forKey: ReviewStore.settingsKey))
        var invalid = original
        invalid.followPeople = true
        invalid.followedAuthorEmails = "alex@example.com; sam@example.com"
        XCTAssertThrowsError(try store.save(invalid, newPAT: "replacement-token"))
        XCTAssertEqual(store.configuration, original)
        XCTAssertEqual(defaults.data(forKey: ReviewStore.settingsKey), saved)
        XCTAssertEqual(store.snapshot, snapshot)
        invalid.sourceURLs = ""
        defaults.set(try JSONEncoder().encode(invalid), forKey: ReviewStore.settingsKey)
        let restored = ReviewStore(defaults: defaults, keychain: keychain, loader: StubReviewLoader([]))
        XCTAssertEqual(restored.errorMessage, ReviewQError.invalidFollowedAuthorEmails.localizedDescription)
        XCTAssertEqual(restored.configuration.followedAuthorEmails, invalid.followedAuthorEmails)
    }

    func testInvalidSettingsCannotReplaceSavedConfiguration() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        let original = configuration()
        try store.save(original)
        XCTAssertThrowsError(try store.save(configuration("https://evil.test/Project")))
        XCTAssertEqual(store.configuration, original)
    }

    func testCorruptPersistedSettingsAreVisible() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: ReviewStore.settingsKey)
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.menuBarTitle, " !")
    }

    func testDeletingActivePATClearsTheQueueAndSurfacesMissingCredential() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ReviewStore(
            defaults: defaults, keychain: StubPATStore(),
            loader: StubReviewLoader([.success(ReviewSnapshot(pullRequests: []))])
        )
        var settings = configuration()
        settings.authentication = .personalAccessToken
        try store.save(settings)
        await store.refresh()
        XCTAssertNotNil(store.snapshot)
        try store.deleteSavedPAT()
        XCTAssertNil(store.snapshot)
        XCTAssertNotNil(store.errorMessage)
    }

    func testChangingSourcesRejectsAnOldInFlightResponse() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let loader = DeferredReviewLoader()
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(configuration())
        let refresh = Task { await store.refresh() }
        await loader.waitUntilStarted()
        let replacement = configuration("https://dev.azure.com/another/Project")
        try store.save(replacement)
        await loader.finish(ReviewSnapshot(pullRequests: []))
        await refresh.value
        XCTAssertEqual(store.configuration, replacement)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.menuBarTitle, " ...")
    }
}
