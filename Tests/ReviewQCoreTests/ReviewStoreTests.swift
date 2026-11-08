import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class ReviewStoreTests: XCTestCase {
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
        let store = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        try store.save(settings, newPAT: "synthetic-token")
        let data = try XCTUnwrap(defaults.data(forKey: ReviewStore.settingsKey))
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("synthetic-token"))
        let restored = ReviewStore(defaults: defaults, keychain: StubPATStore(), loader: StubReviewLoader([]))
        XCTAssertEqual(restored.configuration, settings)
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
