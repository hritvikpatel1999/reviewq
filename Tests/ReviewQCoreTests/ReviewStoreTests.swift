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

    func testArchivingMovesAllQueueKindsWithoutChangingTheSnapshotCacheOrNetwork() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = configuration("https://dev.azure.com/example/Project\nhttps://dev.azure.com/another/Project")
        settings.followPeople = true
        settings.followedAuthorEmails = "alex@example.com"
        settings.showAuthoredPullRequests = true
        let assigned = try cachedRequest(1)
        let followed = try cachedRequest(2, followed: true)
        let authored = try cachedRequest(3, authored: true)
        let otherRepository = try cachedRequest(1, repositoryID: "other-id")
        let otherOrganization = try cachedRequest(1, organization: "another")
        var snapshot = ReviewSnapshot(pullRequests: [assigned, followed, authored, otherRepository, otherOrganization])
        snapshot.identityScope = String(repeating: "a", count: 64)
        let loader = StubReviewLoader([])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(settings, verifiedSnapshot: snapshot)
        let cached = defaults.data(forKey: ReviewQueueCache.settingsKey)
        XCTAssertEqual(store.pendingReviewCount, 3)
        for request in [assigned, followed, authored, assigned] { store.archive(request) }
        XCTAssertNil(store.archiveErrorMessage)
        XCTAssertEqual(Set(store.activePullRequests.map(\.id)), [otherRepository.id, otherOrganization.id])
        XCTAssertEqual(Set(store.archivedPullRequests.map(\.id)), [assigned.id, followed.id, authored.id])
        XCTAssertEqual(store.pendingReviewCount, 2)
        XCTAssertEqual(store.menuBarTitle, " 2")
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertEqual(defaults.data(forKey: ReviewQueueCache.settingsKey), cached)
        store.restore(followed)
        XCTAssertEqual(store.pendingReviewCount, 2)
        store.restore(assigned)
        XCTAssertEqual(store.pendingReviewCount, 3)
        XCTAssertEqual(store.archivedPullRequests, [authored])
        XCTAssertFalse(store.changes.hasChanges, "Local archive actions must not invent a server refresh change.")
        let calls = await loader.calls
        XCTAssertEqual(calls, 0)
        let saved = try XCTUnwrap(defaults.data(forKey: ReviewStore.archivesKey))
        let text = try XCTUnwrap(String(data: saved, encoding: .utf8))
        XCTAssertFalse(text.contains("Original"))
        XCTAssertFalse(text.contains("Fixture author"))
        XCTAssertFalse(text.contains("https://"))
    }

    func testArchivesSurviveFailuresDisappearanceAndCachedRelaunchWithoutReturningToActiveLists() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let archived = try cachedRequest(1)
        let active = try cachedRequest(2)
        let scope = String(repeating: "a", count: 64)
        var baseline = ReviewSnapshot(pullRequests: [archived, active])
        baseline.identityScope = scope
        var empty = ReviewSnapshot(pullRequests: [])
        empty.identityScope = scope
        let updated = try cachedRequest(1, title: "Updated while archived")
        var returned = ReviewSnapshot(pullRequests: [updated, active])
        returned.identityScope = scope
        let loader = StubReviewLoader([
            .failure(.http(503, "example/Project")), .success(empty), .success(returned)
        ])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(configuration(), verifiedSnapshot: baseline)
        store.archive(archived)
        let choices = defaults.data(forKey: ReviewStore.archivesKey)
        await store.refresh()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.archivedPullRequests, [archived])
        XCTAssertEqual(store.menuBarTitle, " 1 !")
        await store.refresh()
        XCTAssertTrue(store.archivedPullRequests.isEmpty)
        XCTAssertEqual(defaults.data(forKey: ReviewStore.archivesKey), choices)
        await store.refresh()
        XCTAssertEqual(store.archivedPullRequests, [updated])
        XCTAssertEqual(store.activePullRequests, [active])

        let deferred = DeferredScopedReviewLoader(scope: scope)
        let reopened = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: deferred)
        XCTAssertTrue(reopened.archivedPullRequests.isEmpty, "Do not show another account's data before authentication.")
        let refresh = Task { await reopened.refresh() }
        await deferred.waitUntilStarted()
        XCTAssertTrue(reopened.isRefreshing)
        XCTAssertEqual(reopened.archivedPullRequests, [updated])
        XCTAssertEqual(reopened.activePullRequests, [active])
        XCTAssertEqual(reopened.menuBarTitle, " 1")
        await deferred.finish(.failure(.http(503, "example/Project")))
        await refresh.value
        reopened.restore(updated)
        XCTAssertTrue(reopened.archivedPullRequests.isEmpty)
        XCTAssertEqual(Set(reopened.activePullRequests.map(\.id)), [updated.id, active.id])
        XCTAssertEqual(reopened.menuBarTitle, " 2 !")
    }

    func testArchivesAreScopedToTheAuthenticatedQueueAndSurviveLocalPreferenceChanges() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let request = try cachedRequest(1)
        var firstAccount = ReviewSnapshot(pullRequests: [request])
        firstAccount.identityScope = String(repeating: "a", count: 64)
        var otherAccount = firstAccount
        otherAccount.identityScope = String(repeating: "b", count: 64)
        let loader = StubReviewLoader([.success(otherAccount), .success(firstAccount)])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        var settings = configuration()
        settings.authentication = .personalAccessToken
        try store.save(settings, verifiedSnapshot: firstAccount)
        store.archive(request)
        await store.refresh()
        XCTAssertEqual(store.activePullRequests, [request])
        XCTAssertTrue(store.archivedPullRequests.isEmpty)
        XCTAssertFalse(store.changes.hasChanges)
        await store.refresh()
        XCTAssertTrue(store.activePullRequests.isEmpty)
        XCTAssertEqual(store.archivedPullRequests, [request])
        settings.refreshInterval = .fiveMinutes
        try store.save(settings, verifiedSnapshot: firstAccount)
        XCTAssertEqual(store.archivedPullRequests, [request])
        let choices = defaults.data(forKey: ReviewStore.archivesKey)
        try store.deleteSavedPAT()
        XCTAssertTrue(store.archivedPullRequests.isEmpty)
        XCTAssertTrue(store.activePullRequests.isEmpty)
        XCTAssertEqual(defaults.data(forKey: ReviewStore.archivesKey), choices)
    }

    func testArchivedChangesDoNotLightActiveSectionsAndRestoringDoesNotInventChanges() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = configuration()
        settings.followPeople = true
        settings.followedAuthorEmails = "alex@example.com"
        settings.showAuthoredPullRequests = true
        let assigned = try cachedRequest(1)
        let followed = try cachedRequest(2, followed: true)
        let authored = try cachedRequest(3, authored: true)
        let active = try cachedRequest(4)
        let changedActive = try cachedRequest(4, title: "Active update")
        var baseline = ReviewSnapshot(pullRequests: [assigned, followed, authored, active])
        baseline.identityScope = String(repeating: "a", count: 64)
        var archivedChanges = ReviewSnapshot(pullRequests: [
            try cachedRequest(1, title: "Archived update"),
            try cachedRequest(2, title: "Followed update", followed: true),
            try cachedRequest(3, title: "Authored update", authored: true), active
        ])
        archivedChanges.identityScope = baseline.identityScope
        var activeChanges = ReviewSnapshot(pullRequests: Array(archivedChanges.pullRequests.prefix(3)) + [changedActive])
        activeChanges.identityScope = baseline.identityScope
        let loader = StubReviewLoader([.success(archivedChanges), .success(activeChanges)])
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: loader)
        try store.save(settings, verifiedSnapshot: baseline)
        for request in [assigned, followed, authored] { store.archive(request) }
        store.restore(assigned)
        XCTAssertFalse(store.changes.hasChanges)
        store.archive(assigned)
        await store.refresh()
        XCTAssertFalse(store.changes.hasChanges, "Changes to archived PRs must not light the active queue or menu bar.")
        XCTAssertEqual(store.archivedPullRequests.first?.title, "Archived update")
        store.restore(assigned)
        XCTAssertEqual(store.changes.pullRequestIDs, [assigned.id], "Restoring may reveal a real change from the last refresh.")
        store.archive(assigned)
        XCTAssertFalse(store.changes.hasChanges)
        await store.refresh()
        XCTAssertEqual(store.changes.pullRequestIDs, [active.id])
        XCTAssertEqual(store.changes.repositoryIDs, [active.groupID])
        XCTAssertFalse(store.changes.followedPeople)
        XCTAssertFalse(store.changes.authoredPullRequests)
        store.restore(followed)
        XCTAssertEqual(store.changes.pullRequestIDs, [active.id])
    }

    func testFullArchiveRefusesAnAdditionalPRWithoutHidingItAndCanRecoverAfterRestore() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = String(repeating: "a", count: 64)
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "scopes": [scope: (1...4_096).map { "example/service-id/\($0)" }]
        ])
        defaults.set(data, forKey: ReviewStore.archivesKey)
        let archived = try cachedRequest(4_096)
        let additional = try cachedRequest(4_097)
        var snapshot = ReviewSnapshot(pullRequests: [archived, additional])
        snapshot.identityScope = scope
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        try store.save(configuration(), verifiedSnapshot: snapshot)
        store.archive(additional)
        XCTAssertNotNil(store.archiveErrorMessage)
        XCTAssertEqual(store.activePullRequests, [additional])
        XCTAssertEqual(store.archivedPullRequests, [archived])
        XCTAssertEqual(defaults.data(forKey: ReviewStore.archivesKey), data)
        store.restore(archived)
        store.archive(additional)
        XCTAssertNil(store.archiveErrorMessage)
        XCTAssertEqual(store.activePullRequests, [archived])
        XCTAssertEqual(store.archivedPullRequests, [additional])
    }

    func testInvalidArchiveStateAndUnavailableActionsAreVisibleAndLogNoPRDetails() throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewQ-archive-tests-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Could not remove test logs: \(error)") }
        }
        let diagnostics = DiagnosticLogger(directory: directory)
        let invalid = try JSONSerialization.data(withJSONObject: [
            "version": 1, "scopes": [String(repeating: "a", count: 64): ["PRIVATE_ARCHIVE_PAYLOAD"]]
        ])
        for data in [Data("PRIVATE_ARCHIVE_PAYLOAD".utf8), invalid, Data(repeating: 0, count: 512 * 1_024 + 1)] {
            defaults.set(data, forKey: ReviewStore.archivesKey)
            let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]), diagnostics: diagnostics)
            XCTAssertNotNil(store.archiveErrorMessage)
            XCTAssertNil(defaults.object(forKey: ReviewStore.archivesKey))
        }
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]), diagnostics: diagnostics)
        let request = try cachedRequest(1, title: "PRIVATE_ARCHIVE_TITLE")
        try store.save(configuration(), verifiedSnapshot: ReviewSnapshot(pullRequests: [request]))
        store.archive(request)
        XCTAssertNotNil(store.archiveErrorMessage)
        XCTAssertEqual(store.activePullRequests, [request])
        XCTAssertNil(defaults.object(forKey: ReviewStore.archivesKey))
        XCTAssertNil(store.errorMessage, "A local action failure is not an Azure DevOps refresh error.")
        diagnostics.flush()
        let log = try String(contentsOf: directory.appendingPathComponent("warnings-errors.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("archiveStateInvalidated"))
        XCTAssertTrue(log.contains("archiveChangeFailed"))
        XCTAssertFalse(log.contains("PRIVATE_ARCHIVE"))
        XCTAssertFalse(log.contains(request.url.absoluteString))
    }

    private func cachedRequest(
        _ number: Int, title: String = "Original", organization: String = "example",
        repositoryID: String = "service-id", followed: Bool = false, authored: Bool = false
    ) throws -> ReviewPullRequest {
        var request = ReviewPullRequest(
            number: number, title: title, author: "Fixture author", organization: organization,
            project: "Project", repository: "Service", repositoryID: repositoryID, createdAt: .distantPast,
            url: try AzureDevOpsURL.make(
                organization: organization, path: ["Project", "_git", repositoryID, "pullrequest", String(number)]
            ),
            isRequired: true, isDraft: false, reviewStage: .commented,
            commentResolution: ReviewCommentResolution(resolvedCount: 2, openCount: 1),
            isFollowedOnly: followed,
            authoredStatus: authored ? AuthoredPullRequestStatus(activeCommentCount: 0, hasRequiredApprovals: false) : nil
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
