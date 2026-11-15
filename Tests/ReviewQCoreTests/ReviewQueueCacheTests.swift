import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class ReviewQueueCacheTests: XCTestCase {
    func testOnlyQueueAffectingPreferencesInvalidateCachedDisplayData() throws {
        let name = "ReviewQ-queue-cache-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = ReviewQueueCache(defaults: defaults)
        let snapshot = try fixture()
        cache.save(snapshot, configuration: configuration())
        var displayChanges = configuration(" https://dev.azure.com/example/Project\n")
        displayChanges.showCount = false
        displayChanges.refreshInterval = .oneMinute
        displayChanges.copilotAdditionalInstructions = "Synthetic instructions not stored in the queue."
        XCTAssertEqual(cache.load(configuration: displayChanges, identityScope: scope), snapshot)
        let stored = try XCTUnwrap(defaults.data(forKey: ReviewQueueCache.settingsKey))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("Synthetic instructions"))

        for option in 0..<3 {
            cache.save(snapshot, configuration: configuration())
            var changed = configuration()
            if option == 0 { changed.includeDrafts = true }
            if option == 1 { changed.showAuthoredPullRequests = true }
            if option == 2 {
                changed.followPeople = true
                changed.followedAuthorEmails = "alex@example.com"
            }
            XCTAssertNil(cache.load(configuration: changed, identityScope: scope))
            XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
        }
    }

    func testCacheExpiryAndMalformedOrOversizedDataAreDiscardedWithoutInventingAnEmptyQueue() throws {
        let name = "ReviewQ-queue-cache-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ReviewQueueCache(defaults: defaults, clock: { now })
        let almostExpired = try fixture(updatedAt: now.addingTimeInterval(-ReviewQueueCache.lifetime + 1))
        cache.save(almostExpired, configuration: configuration())
        XCTAssertEqual(cache.load(configuration: configuration(), identityScope: scope), almostExpired)
        for date in [now.addingTimeInterval(-ReviewQueueCache.lifetime), now.addingTimeInterval(1)] {
            cache.save(try fixture(updatedAt: date), configuration: configuration())
            XCTAssertNil(cache.load(configuration: configuration(), identityScope: scope))
            XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
        }
        for corrupt in [Data("broken".utf8), Data(repeating: 0, count: ReviewQueueCache.maximumBytes + 1)] {
            defaults.set(corrupt, forKey: ReviewQueueCache.settingsKey)
            XCTAssertNil(cache.load(configuration: configuration(), identityScope: scope))
            XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
        }
    }

    func testCachePreservesFollowedAndAuthoredBadgesButRejectsUnsafeURLsDuplicatesAndOversize() throws {
        let name = "ReviewQ-queue-cache-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = ReviewQueueCache(defaults: defaults)
        var settings = configuration()
        settings.followPeople = true
        settings.followedAuthorEmails = "alex@example.com"
        settings.showAuthoredPullRequests = true
        let followed = try request(1, followed: true)
        let authored = try request(2, authored: AuthoredPullRequestStatus(activeCommentCount: 3, hasRequiredApprovals: false))
        var snapshot = ReviewSnapshot(pullRequests: [followed, authored])
        snapshot.identityScope = scope
        cache.save(snapshot, configuration: settings)
        XCTAssertEqual(cache.load(configuration: settings, identityScope: scope), snapshot)

        var invalid = ReviewSnapshot(pullRequests: [try request(1, url: URL(string: "https://unexpected.invalid/pr/1"))])
        invalid.identityScope = scope
        cache.save(invalid, configuration: settings)
        XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
        invalid = ReviewSnapshot(pullRequests: [followed, followed])
        invalid.identityScope = scope
        cache.save(invalid, configuration: settings)
        XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey))
        invalid = ReviewSnapshot(pullRequests: [try request(1, title: String(repeating: "x", count: ReviewQueueCache.maximumBytes))])
        invalid.identityScope = scope
        cache.save(invalid, configuration: settings)
        XCTAssertNil(defaults.object(forKey: ReviewQueueCache.settingsKey), "Oversized queues are not silently truncated.")
    }

    private var scope: String { String(repeating: "a", count: 64) }

    private func fixture(updatedAt: Date = .now) throws -> ReviewSnapshot {
        var snapshot = ReviewSnapshot(pullRequests: [try request(1)], updatedAt: updatedAt)
        snapshot.identityScope = scope
        return snapshot
    }

    private func request(
        _ number: Int, followed: Bool = false, authored: AuthoredPullRequestStatus? = nil,
        url: URL? = nil, title: String = "Synthetic cached PR"
    ) throws -> ReviewPullRequest {
        ReviewPullRequest(
            number: number, title: title, author: "Synthetic author", organization: "example",
            project: "Project", repository: "Service", repositoryID: "service-id", createdAt: .distantPast,
            url: try url ?? AzureDevOpsURL.make(
                organization: "example", path: ["Project", "_git", "service-id", "pullrequest", String(number)]
            ),
            isRequired: false, isDraft: false, reviewStage: .firstReview,
            isFollowedOnly: followed, authoredStatus: authored
        )
    }
}
