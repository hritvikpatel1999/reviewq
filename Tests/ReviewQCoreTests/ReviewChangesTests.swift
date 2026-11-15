import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class ReviewChangesTests: XCTestCase {
    func testArrivalsUpdatesMovesAndRemovalsPropagateToTheirSections() {
        let unchanged = request(1)
        let updated = request(2, title: "Updated")
        let moved = request(4, authored: true)
        let arrived = request(6, followed: true)
        let previous = ReviewSnapshot(pullRequests: [
            unchanged, request(2), request(3, repository: "Removed"), request(4, followed: true)
        ])
        let current = ReviewSnapshot(pullRequests: [arrived, moved, updated, unchanged])
        let changes = ReviewChanges(previous: previous, current: current)
        XCTAssertEqual(changes.pullRequestIDs, [updated.id, moved.id, arrived.id])
        XCTAssertEqual(changes.repositoryIDs, [updated.groupID, request(3, repository: "Removed").groupID])
        XCTAssertTrue(changes.followedPeople)
        XCTAssertTrue(changes.authoredPullRequests)

        let removal = ReviewChanges(
            previous: ReviewSnapshot(pullRequests: [unchanged]), current: ReviewSnapshot(pullRequests: [])
        )
        XCTAssertTrue(removal.hasChanges)
        XCTAssertTrue(removal.pullRequestIDs.isEmpty, "A removed PR must not invent a card.")
        XCTAssertEqual(removal.repositoryIDs, [unchanged.groupID])
        XCTAssertFalse(ReviewChanges(previous: nil, current: current).hasChanges)
    }

    func testAccountChangesEstablishANewBaselineInsteadOfComparingDifferentUsers() {
        var old = ReviewSnapshot(pullRequests: [request(1)])
        old.identityScope = "synthetic-account-a"
        var new = ReviewSnapshot(pullRequests: [request(2)])
        new.identityScope = "synthetic-account-b"
        XCTAssertFalse(ReviewChanges(previous: old, current: new).hasChanges)
        new.identityScope = old.identityScope
        XCTAssertTrue(ReviewChanges(previous: old, current: new).hasChanges)
    }

    func testExistingResponsesDetectSourceVotesAndDiscussionChangesWithoutAdditionalRequests() async throws {
        let original = try await load(pullRequest(), threads: [thread()])
        let variants: [(String, [String])] = [
            (pullRequest(commit: "source-b"), [thread()]),
            (pullRequest(otherVote: 10), [thread()]),
            (pullRequest(), [thread(content: "Edited without changing the thread count.")]),
            (pullRequest(), [thread(reply: true)]),
            (pullRequest(), [thread(status: "fixed")]),
            (pullRequest(), [thread(deleted: true)]),
            (pullRequest(), [thread(updated: "2026-11-12T08:01:00Z")])
        ]
        for (pr, threads) in variants {
            let updated = try await load(pr, threads: threads)
            XCTAssertEqual(updated.pullRequests.first?.reviewStage, original.pullRequests.first?.reviewStage)
            XCTAssertNotEqual(updated.pullRequests.first?.changeFingerprint, original.pullRequests.first?.changeFingerprint)
            XCTAssertEqual(
                ReviewChanges(previous: original, current: updated).pullRequestIDs,
                Set(updated.pullRequests.map(\.id))
            )
        }
    }

    func testFingerprintsIgnoreReviewerThreadAndReplyOrderingAndRefreshTime() async throws {
        let first = try await load(
            pullRequest(), threads: [thread(reply: true), thread(id: 2, content: "Another discussion.")]
        )
        let reordered = try await load(
            pullRequest(reverseReviewers: true),
            threads: [thread(id: 2, content: "Another discussion."), thread(reply: true, reverseComments: true)]
        )
        XCTAssertEqual(first.pullRequests, reordered.pullRequests)
        XCTAssertFalse(ReviewChanges(previous: first, current: reordered).hasChanges)
    }

    private func load(_ pr: String, threads: [String]) async throws -> ReviewSnapshot {
        let transport = StubTransport(
            [connectionResponse(), pullRequestsResponse([pr])],
            histories: [1: reviewThreadsResponse(threads)]
        )
        let snapshot = try await AzureDevOpsReviewLoader(
            authorization: StubAuthorization(header: "synthetic-change-test-account"), transport: transport
        ).load(configuration: configuration())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3, "Only the existing identity, PR-list, and discussion requests are allowed.")
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/example/_apis/connectionData", "/example/Project/_apis/git/pullrequests",
            "/example/Project/_apis/git/repositories/repo-id/pullRequests/1/threads"
        ])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        return snapshot
    }

    private func pullRequest(
        commit: String = "source-a", otherVote: Int = 0, reverseReviewers: Bool = false
    ) -> String {
        let reviewers = [
            #"{"id":"\#(reviewerID)","vote":0,"isRequired":true}"#,
            #"{"id":"\#(authorID)","vote":\#(otherVote),"isRequired":false}"#
        ]
        let ordered = reverseReviewers ? Array(reviewers.reversed()) : reviewers
        return pullRequestJSON(reviewersJSON: ordered.joined(separator: ","))
            .replacingOccurrences(
                of: "\"reviewers\":[",
                with: """
                "sourceRefName":"refs/heads/feature","targetRefName":"refs/heads/main",
                "lastMergeSourceCommit":{"commitId":"\(commit)"},"reviewers":[
                """
            )
    }

    private func thread(
        id: Int = 1, content: String = "Original discussion.", status: String = "active",
        reply: Bool = false, reverseComments: Bool = false, deleted: Bool = false,
        updated: String = "2026-11-12T08:00:00Z"
    ) -> String {
        var comments = [
            #"{"id":1,"author":{"id":"\#(authorID)"},"commentType":"text","content":"\#(content)","isDeleted":\#(deleted)}"#
        ]
        if reply {
            comments.append(
                #"{"id":2,"parentCommentId":1,"author":{"id":"\#(authorID)"},"commentType":"text","content":"A reply."}"#
            )
        }
        if reverseComments { comments.reverse() }
        return """
        {"id":\(id),"status":"\(status)","lastUpdatedDate":"\(updated)",
         "comments":[\(comments.joined(separator: ","))]}
        """
    }

    private func request(
        _ number: Int, title: String = "Original", repository: String = "Service",
        followed: Bool = false, authored: Bool = false
    ) -> ReviewPullRequest {
        ReviewPullRequest(
            number: number, title: title, author: "Fixture author", organization: "example",
            project: "Project", repository: repository, repositoryID: repository.lowercased(),
            createdAt: .distantPast,
            url: URL(string: "https://dev.azure.com/example/Project/_git/repo/pullrequest/\(number)")!,
            isRequired: false, isDraft: false, reviewStage: .firstReview, isFollowedOnly: followed,
            authoredStatus: authored ? AuthoredPullRequestStatus(activeCommentCount: 0, hasRequiredApprovals: false) : nil
        )
    }
}
