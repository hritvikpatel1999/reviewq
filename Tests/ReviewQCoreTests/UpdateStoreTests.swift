import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class UpdateStoreTests: XCTestCase {
    func testDailyBoundaryCacheRestorationAndConditionalChecksPersistAcrossRestarts() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = UpdateClock()
        let release = try update("3.1.2")
        let client = UpdateClientFake([.success(.modified(release: release, entityTag: "\"first\"")), .success(.notModified)])
        let first = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, clock: { clock.now })
        await first.check()
        XCTAssertEqual(first.bannerUpdate, release)
        let checked = first.lastCheckedAt
        clock.advance(24 * 3_600 - 1)
        let reopened = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, clock: { clock.now })
        XCTAssertEqual(reopened.bannerUpdate, release, "Cached banner information must be available before a request.")
        await reopened.check()
        var tags = await client.tags
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(reopened.lastCheckedAt, checked)
        clock.advance(1)
        await reopened.check()
        tags = await client.tags
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags.last, "\"first\"")
        XCTAssertEqual(reopened.bannerUpdate, release)
        XCTAssertEqual(reopened.lastCheckedAt, clock.now)
    }

    func testDismissalIsPerVersionAndManualChecksCanDiscoverANewReleaseBeforeTheDailyDeadline() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let firstRelease = try update("3.1.2")
        let nextRelease = try update("3.2.0")
        let client = UpdateClientFake([
            .success(.modified(release: firstRelease, entityTag: nil)),
            .success(.modified(release: nextRelease, entityTag: nil))
        ])
        let first = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client)
        await first.check()
        first.dismissUpdate()
        XCTAssertNil(first.bannerUpdate)
        XCTAssertEqual(first.availableUpdate, firstRelease, "Settings must retain a dismissed update's link.")
        let reopened = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client)
        XCTAssertNil(reopened.bannerUpdate)
        await reopened.check(manually: true)
        XCTAssertEqual(reopened.bannerUpdate, nextRelease)
        let upgraded = UpdateStore(currentVersion: "3.2.0", defaults: defaults, client: client)
        XCTAssertNil(upgraded.availableUpdate)
        XCTAssertNil(upgraded.bannerUpdate)
    }

    func testVersionsAreComparedNumericallyAndNeverOfferAnOlderOrEqualRelease() async throws {
        for (installed, latest, offered) in [
            ("3.1.9", "3.1.10", true), ("3.9.9", "3.10.0", true),
            ("3.10.0", "3.9.9", false), ("3.1.1", "3.1.1", false), ("4.0.0", "3.9.9", false)
        ] {
            let (defaults, name) = try preferences()
            defer { defaults.removePersistentDomain(forName: name) }
            let client = UpdateClientFake([.success(.modified(release: try update(latest), entityTag: nil))])
            let store = UpdateStore(currentVersion: installed, defaults: defaults, client: client)
            await store.check()
            XCTAssertEqual(store.availableUpdate != nil, offered, "\(installed) -> \(latest)")
        }
    }

    func testOfflineFailureKeepsTheBannerAndLastSuccessAndBacksOffAcrossRestarts() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = UpdateClock()
        let release = try update("3.1.2")
        let client = UpdateClientFake([
            .success(.modified(release: release, entityTag: "\"cached\"")),
            .failure(URLError(.notConnectedToInternet)), .failure(URLError(.notConnectedToInternet)),
            .success(.notModified)
        ])
        let store = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, clock: { clock.now })
        await store.check()
        let lastSuccess = store.lastCheckedAt
        clock.advance(24 * 3_600)
        await store.check()
        XCTAssertEqual(store.bannerUpdate, release)
        XCTAssertEqual(store.lastCheckedAt, lastSuccess)
        XCTAssertNotNil(store.errorMessage)
        let reopened = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, clock: { clock.now })
        clock.advance(15 * 60 - 1)
        await reopened.check()
        var tags = await client.tags
        XCTAssertEqual(tags.count, 2)
        clock.advance(1)
        await reopened.check()
        tags = await client.tags
        XCTAssertEqual(tags.count, 3)
        XCTAssertEqual(reopened.lastCheckedAt, lastSuccess)
        XCTAssertNotNil(reopened.errorMessage)
        clock.advance(30 * 60 - 1)
        await reopened.check()
        tags = await client.tags
        XCTAssertEqual(tags.count, 3, "The second failure doubles the automatic retry delay.")
        clock.advance(1)
        await reopened.check()
        tags = await client.tags
        XCTAssertEqual(tags.count, 4)
        XCTAssertEqual(reopened.lastCheckedAt, clock.now)
        XCTAssertNil(reopened.errorMessage)
    }

    func testManualChecksRespectServerBackoffEvenAfterRestarting() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = UpdateClock()
        let deadline = clock.now.addingTimeInterval(7_200)
        let client = UpdateClientFake([
            .failure(UpdateCheckError.http(429, retryAt: deadline, rateLimited: true)),
            .success(.modified(release: nil, entityTag: nil))
        ])
        let store = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, clock: { clock.now })
        await store.check(manually: true)
        XCTAssertNil(store.lastCheckedAt)
        let reopened = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, clock: { clock.now })
        clock.advance(7_199)
        await reopened.check(manually: true)
        var tags = await client.tags
        XCTAssertEqual(tags.count, 1)
        XCTAssertTrue(reopened.errorMessage?.contains("paused") == true)
        clock.advance(1)
        await reopened.check(manually: true)
        tags = await client.tags
        XCTAssertEqual(tags.count, 2)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertNotNil(reopened.lastCheckedAt)
    }

    func testConcurrentTriggersShareOneRequestAndCancelledResultsAreNotPublished() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = DeferredUpdateClient()
        let store = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client)
        let first = Task { await store.check() }
        await client.waitUntilStarted()
        XCTAssertTrue(store.isChecking)
        await store.check(manually: true)
        store.requestCheck()
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
        first.cancel()
        await client.finish(.modified(release: try update("3.1.2"), entityTag: "\"cancelled\""))
        await first.value
        XCTAssertFalse(store.isChecking)
        XCTAssertNil(store.availableUpdate)
        XCTAssertNil(store.lastCheckedAt)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(defaults.object(forKey: UpdateStore.settingsKey))
    }

    func testMissingVersionAndUncachedNotModifiedCannotClaimASuccessfulCheck() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let client = UpdateClientFake([.success(.notModified)])
        let development = UpdateStore(currentVersion: nil, defaults: defaults, client: client)
        await development.check(manually: true)
        let tags = await client.tags
        XCTAssertTrue(tags.isEmpty)
        XCTAssertNotNil(development.errorMessage)
        let packaged = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client)
        await packaged.check()
        XCTAssertNotNil(packaged.errorMessage)
        XCTAssertNil(packaged.lastCheckedAt)
        XCTAssertNil(packaged.availableUpdate)
    }

    func testCorruptOrUntrustedCachedReleasesAreClearedAndFailuresAreLoggedWithoutPayloads() async throws {
        let (defaults, name) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewQ-update-tests-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Could not remove test logs: \(error)") }
        }
        let logger = DiagnosticLogger(directory: directory)
        let client = UpdateClientFake([.success(.modified(release: try update("3.1.2"), entityTag: "\"valid\""))])
        let store = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client)
        await store.check()
        let data = try XCTUnwrap(defaults.data(forKey: UpdateStore.settingsKey))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var release = try XCTUnwrap(object["release"] as? [String: Any])
        release["releaseURL"] = "https://untrusted.invalid/PRIVATE_UPDATE_PAYLOAD"
        object["release"] = release
        let tampered = try JSONSerialization.data(withJSONObject: object)
        for corrupt in [Data("PRIVATE_UPDATE_PAYLOAD".utf8), Data(repeating: 0, count: 32 * 1_024 + 1), tampered] {
            defaults.set(corrupt, forKey: UpdateStore.settingsKey)
            let restored = UpdateStore(currentVersion: "3.1.1", defaults: defaults, client: client, diagnostics: logger)
            XCTAssertNil(restored.bannerUpdate)
            XCTAssertNotNil(restored.errorMessage)
            XCTAssertNil(defaults.object(forKey: UpdateStore.settingsKey))
        }
        let failing = UpdateStore(
            currentVersion: "3.1.1", defaults: defaults,
            client: UpdateClientFake([.failure(URLError(.notConnectedToInternet))]), diagnostics: logger
        )
        await failing.check()
        logger.flush()
        let log = try String(contentsOf: directory.appendingPathComponent("warnings-errors.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("updateCacheInvalidated"))
        XCTAssertTrue(log.contains("updateCheckFailed"))
        XCTAssertTrue(log.contains("offline"))
        XCTAssertFalse(log.contains("PRIVATE_UPDATE_PAYLOAD"))
        XCTAssertFalse(log.contains("untrusted.invalid"))
    }

    private func update(_ version: String) throws -> AvailableUpdate {
        try AvailableUpdate(
            version: version,
            releaseURL: XCTUnwrap(URL(string: "https://github.com/hritvikpatel1999/reviewq/releases/tag/v\(version)"))
        )
    }

    private func preferences() throws -> (UserDefaults, String) {
        let name = "ReviewQ-update-tests-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
}

@MainActor
private final class UpdateClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private actor UpdateClientFake: UpdateChecking {
    var outcomes: [Result<UpdateCheckResult, any Error>]
    private(set) var tags: [String?] = []

    init(_ outcomes: [Result<UpdateCheckResult, any Error>]) { self.outcomes = outcomes }

    func check(entityTag: String?) throws -> UpdateCheckResult {
        tags.append(entityTag)
        guard !outcomes.isEmpty else { throw UpdateCheckError.invalidResponse }
        return try outcomes.removeFirst().get()
    }
}

private actor DeferredUpdateClient: UpdateChecking {
    private(set) var calls = 0
    private var pending: CheckedContinuation<UpdateCheckResult, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func check(entityTag: String?) async -> UpdateCheckResult {
        calls += 1
        return await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: UpdateCheckResult) {
        pending?.resume(returning: result)
        pending = nil
    }
}
