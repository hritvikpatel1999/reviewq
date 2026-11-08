import Foundation
@testable import ReviewQCore
import XCTest

@MainActor
final class ReviewHistoryTests: XCTestCase {
    func testStagesUseTheCurrentReviewersFeedbackRatherThanSystemOrOtherReviewersActivity() async throws {
        let transport = StubTransport(
            [
                connectionResponse(),
                pullRequestsResponse((1...11).map { pullRequestJSON(number: $0) })
            ],
            histories: [
                2: reviewThreadsResponse([voteThreadJSON(voter: reviewerID.uppercased())]),
                3: reviewThreadsResponse([reviewCommentThreadJSON()]),
                4: reviewThreadsResponse([voteThreadJSON(voter: authorID)]),
                5: reviewThreadsResponse([reviewCommentThreadJSON(author: authorID)]),
                6: reviewThreadsResponse([voteThreadJSON(vote: 0)]),
                7: reviewThreadsResponse([reviewCommentThreadJSON(type: "system")]),
                8: reviewThreadsResponse([reviewCommentThreadJSON(deleted: true)]),
                9: reviewThreadsResponse([voteThreadJSON(vote: -5, numeric: true)]),
                10: reviewThreadsResponse([reviewCommentThreadJSON(type: "codeChange")]),
                11: reviewThreadsResponse([voteThreadJSON(), voteThreadJSON(vote: 0)])
            ]
        )
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let result = try await loader.load(configuration: configuration())
        let stages = Dictionary(uniqueKeysWithValues: result.pullRequests.map { ($0.number, $0.reviewStage) })
        XCTAssertEqual(stages, [
            1: .firstReview, 2: .reReview, 3: .reReview, 4: .firstReview, 5: .firstReview,
            6: .firstReview, 7: .firstReview, 8: .reReview, 9: .reReview, 10: .firstReview,
            11: .reReview
        ])
        let requests = await transport.requests.filter { $0.url?.path.hasSuffix("/threads") == true }
        XCTAssertEqual(requests.count, 11)
        XCTAssertTrue(requests.allSatisfy {
            $0.url?.path.contains("/_apis/git/repositories/repo-id/pullRequests/") == true
                && $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") != nil
        })
    }

    func testNewFeedbackIsDetectedOnTheNextRefresh() async throws {
        let transport = StubTransport([
            connectionResponse(), pullRequestsResponse([pullRequestJSON()]),
            connectionResponse(), pullRequestsResponse([pullRequestJSON()])
        ])
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let first = try await loader.load(configuration: configuration())
        XCTAssertEqual(first.pullRequests.first?.reviewStage, .firstReview)
        await transport.setHistory(reviewThreadsResponse([reviewCommentThreadJSON()]), for: 1)
        let next = try await loader.load(configuration: configuration())
        XCTAssertEqual(next.pullRequests.first?.reviewStage, .reReview)
    }

    func testLegacyCommentsWithoutTypesUseAuthorshipAndDiscussionEvidence() async throws {
        let transport = StubTransport(
            [connectionResponse(), pullRequestsResponse((1...8).map { pullRequestJSON(number: $0) })],
            histories: [
                1: reviewThreadsResponse([reviewCommentThreadJSON(type: nil, content: "Fixture feedback")]),
                2: reviewThreadsResponse([
                    reviewCommentThreadJSON(author: authorID, type: nil, content: "Fixture feedback")
                ]),
                3: reviewThreadsResponse([
                    reviewCommentThreadJSON(type: nil, content: "Automatic activity", threadType: "RefUpdate")
                ]),
                4: reviewThreadsResponse([reviewCommentThreadJSON(type: nil, deleted: true)]),
                5: reviewThreadsResponse([reviewCommentThreadJSON(type: nil, content: "   ")]),
                6: reviewThreadsResponse([
                    reviewCommentThreadJSON(type: "unknown", content: "Fixture feedback")
                ]),
                7: reviewThreadsResponse([
                    reviewCommentThreadJSON(type: "unknown", deleted: true, threadType: "PolicyUpdate")
                ]),
                8: reviewThreadsResponse(["""
                    {"comments":[{"author":{"id":"\(reviewerID)"},
                      "commentType":null,"content":"Fixture feedback"}]}
                    """])
            ]
        )
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let result = try await loader.load(configuration: configuration())
        let stages = Dictionary(uniqueKeysWithValues: result.pullRequests.map { ($0.number, $0.reviewStage) })
        XCTAssertEqual(stages, [
            1: .reReview, 2: .firstReview, 3: .firstReview, 4: .reReview,
            5: .firstReview, 6: .reReview, 7: .firstReview, 8: .reReview
        ])
    }

    func testTypedFeedbackStillCountsInAThreadWithSystemActivity() async throws {
        let transport = StubTransport(
            [connectionResponse(), pullRequestsResponse([pullRequestJSON()])],
            histories: [1: reviewThreadsResponse([
                reviewCommentThreadJSON(content: "Fixture feedback", threadType: "RefUpdate")
            ])]
        )
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let result = try await loader.load(configuration: configuration())
        XCTAssertEqual(result.pullRequests.first?.reviewStage, .reReview)
    }

    func testLegacyVotesResolveTheVoterFromTheThreadIdentityTable() async throws {
        let zeroWithoutVoter = """
        {"comments":[],"properties":{
          "CodeReviewThreadType":{"$value":"VoteUpdate"},
          "CodeReviewVoteResult":{"$value":"0"}
        }}
        """
        let transport = StubTransport(
            [connectionResponse(), pullRequestsResponse((1...6).map { pullRequestJSON(number: $0) })],
            histories: [
                1: reviewThreadsResponse([voteThreadJSON(useIdentityReference: true)]),
                2: reviewThreadsResponse([voteThreadJSON(voter: authorID, useIdentityReference: true)]),
                3: reviewThreadsResponse([voteThreadJSON(vote: 0, useIdentityReference: true)]),
                4: reviewThreadsResponse([voteThreadJSON(vote: -5, numeric: true, useIdentityReference: true)]),
                5: reviewThreadsResponse([
                    voteThreadJSON(useIdentityReference: true), voteThreadJSON(vote: 0, useIdentityReference: true)
                ]),
                6: reviewThreadsResponse([zeroWithoutVoter])
            ]
        )
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let result = try await loader.load(configuration: configuration())
        let stages = Dictionary(uniqueKeysWithValues: result.pullRequests.map { ($0.number, $0.reviewStage) })
        XCTAssertEqual(stages, [
            1: .reReview, 2: .firstReview, 3: .firstReview,
            4: .reReview, 5: .reReview, 6: .firstReview
        ])
    }

    func testHistoryUsesEachOrganizationsAuthenticatedIdentity() async throws {
        let otherReviewer = "33333333-3333-3333-3333-333333333333"
        let transport = StubTransport(
            [
                connectionResponse(), pullRequestsResponse([pullRequestJSON()]),
                connectionResponse(otherReviewer),
                pullRequestsResponse([pullRequestJSON(reviewer: otherReviewer)])
            ],
            histories: [1: reviewThreadsResponse([voteThreadJSON()])]
        )
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let result = try await loader.load(configuration: configuration("""
        https://dev.azure.com/example/Project
        https://dev.azure.com/another/Project
        """))
        let stages = Dictionary(uniqueKeysWithValues: result.pullRequests.map { ($0.organization, $0.reviewStage) })
        XCTAssertEqual(stages, ["example": .reReview, "another": .firstReview])
    }

    func testHistoryIsRequestedOnlyForEligiblePendingPRs() async throws {
        let transport = StubTransport([
            connectionResponse(),
            pullRequestsResponse([
                pullRequestJSON(number: 1), pullRequestJSON(number: 2, vote: 10),
                pullRequestJSON(number: 3, draft: true), pullRequestJSON(number: 4, author: reviewerID),
                pullRequestJSON(number: 5, declined: true)
            ])
        ])
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        _ = try await loader.load(configuration: configuration())
        let requests = await transport.requests.filter { $0.url?.path.hasSuffix("/threads") == true }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(requests.first?.url).path.hasSuffix("/pullRequests/1/threads"))
    }

    func testHistoryFailuresDoNotGuessFirstReview() async throws {
        let invalidVote = """
        {"comments":[],"properties":{
          "CodeReviewThreadType":{"$value":"VoteUpdate"},
          "CodeReviewVotedByTfId":{"$value":"\(reviewerID)"},
          "CodeReviewVoteResult":{"$value":"not-a-vote"}
        }}
        """
        let incompleteVote = """
        {"comments":[],"properties":{"CodeReviewThreadType":{"$value":"VoteUpdate"}}}
        """
        let unresolvedVoter = """
        {"comments":[],"properties":{
          "CodeReviewThreadType":{"$value":"VoteUpdate"},
          "CodeReviewVotedByIdentity":{"$value":"1"},
          "CodeReviewVoteResult":{"$value":"10"}
        },"identities":{"2":{"id":"\(reviewerID)"}}}
        """
        let missingVoter = """
        {"comments":[],"properties":{
          "CodeReviewThreadType":{"$value":"VoteUpdate"},
          "CodeReviewVoteResult":{"$value":"10"}
        }}
        """
        let responses = [
            HTTPResult(data: Data(), status: 403),
            HTTPResult(data: Data("<html>Sign in</html>".utf8), status: 200),
            reviewThreadsResponse([invalidVote]), reviewThreadsResponse([incompleteVote]),
            reviewThreadsResponse([unresolvedVoter]), reviewThreadsResponse([missingVoter])
        ]
        for response in responses {
            let loader = AzureDevOpsReviewLoader(
                authorization: StubAuthorization(),
                transport: StubTransport(
                    [connectionResponse(), pullRequestsResponse([pullRequestJSON()])],
                    histories: [1: response]
                )
            )
            do {
                _ = try await loader.load(configuration: configuration())
                XCTFail("Incomplete history must not become a First Review label")
            } catch { XCTAssertTrue(error is ReviewQError) }
        }
    }

    func testHistoryConcurrencyIsBoundedButNotSerial() async throws {
        let transport = ConcurrentHistoryTransport()
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let result = try await loader.load(configuration: configuration())
        XCTAssertEqual(result.pullRequests.count, 12)
        let peak = await transport.peak
        let count = await transport.historyRequests
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(count, 12)
    }

    func testCancellationStopsInFlightHistoryWithoutPublishingGuessedStages() async throws {
        let (events, started) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let transport = ConcurrentHistoryTransport(delay: .seconds(10), started: started)
        let loader = AzureDevOpsReviewLoader(authorization: StubAuthorization(), transport: transport)
        let task = Task { try await loader.load(configuration: configuration()) }
        for await _ in events { break }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A canceled refresh must not publish a successful queue")
        } catch { XCTAssertTrue(error is CancellationError) }
        let active = await transport.active
        let count = await transport.historyRequests
        XCTAssertEqual(active, 0)
        XCTAssertLessThanOrEqual(count, 4)
    }
}

private actor ConcurrentHistoryTransport: HTTPTransport {
    private let delay: Duration
    private let started: AsyncStream<Void>.Continuation?
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var historyRequests = 0

    init(delay: Duration = .milliseconds(20), started: AsyncStream<Void>.Continuation? = nil) {
        self.delay = delay
        self.started = started
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let url = try XCTUnwrap(request.url)
        if url.path.hasSuffix("/connectionData") { return connectionResponse() }
        if url.path.hasSuffix("/git/pullrequests") {
            return pullRequestsResponse((1...12).map { pullRequestJSON(number: $0) })
        }
        guard url.path.hasSuffix("/threads") else {
            throw ReviewQError.invalidResponse("Unexpected synthetic endpoint")
        }
        active += 1
        historyRequests += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if historyRequests == 1 {
            started?.yield(())
            started?.finish()
        }
        try await Task.sleep(for: delay)
        return reviewThreadsResponse()
    }
}
