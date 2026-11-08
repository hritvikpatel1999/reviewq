import Foundation
@testable import ReviewQCore

let reviewerID = "abcdef01-abcd-abcd-abcd-abcdef012345"
let authorID = "22222222-2222-2222-2222-222222222222"

func configuration(_ urls: String = "https://dev.azure.com/example/Project") -> ReviewConfiguration {
    var result = ReviewConfiguration()
    result.sourceURLs = urls
    return result
}

func connectionResponse(_ id: String = reviewerID) -> HTTPResult {
    HTTPResult(data: Data("""
    {"authenticatedUser":{"id":"\(id)","isActive":true}}
    """.utf8), status: 200)
}

func pullRequestJSON(
    number: Int = 1, vote: Int = 0, draft: Bool = false, status: String = "active",
    reviewer: String = reviewerID, author: String = authorID,
    declined: Bool = false, date: String = "2026-10-01T12:30:00.1234567Z"
) -> String {
    """
    {
      "pullRequestId":\(number),"title":"Review fixture \(number)","status":"\(status)",
      "creationDate":"\(date)","isDraft":\(draft),
      "createdBy":{"id":"\(author)","displayName":"Fixture author"},
      "repository":{"id":"repo-id","name":"Repository","project":{"id":"project-id","name":"Project"}},
      "reviewers":[{"id":"\(reviewer)","vote":\(vote),"isRequired":true,"hasDeclined":\(declined)}]
    }
    """
}

func pullRequestsResponse(_ items: [String], status: Int = 200) -> HTTPResult {
    HTTPResult(data: Data("{\"value\":[\(items.joined(separator: ","))]}".utf8), status: status)
}

func reviewThreadsResponse(_ items: [String] = [], status: Int = 200) -> HTTPResult {
    HTTPResult(data: Data("{\"value\":[\(items.joined(separator: ","))]}".utf8), status: status)
}

func voteThreadJSON(
    voter: String = reviewerID, vote: Int = 10, numeric: Bool = false,
    useIdentityReference: Bool = false, id: Int? = nil, publishedDate: String? = nil,
    lastUpdatedDate: String? = nil
) -> String {
    let value = numeric ? String(vote) : "\"\(vote)\""
    let voterProperty = useIdentityReference
        ? "\"CodeReviewVotedByIdentity\":{\"$type\":\"System.String\",\"$value\":\"1\"}"
        : "\"CodeReviewVotedByTfId\":{\"$type\":\"System.String\",\"$value\":\"\(voter)\"}"
    let identitiesField = useIdentityReference ? ",\"identities\":{\"1\":{\"id\":\"\(voter)\"}}" : ""
    let idField = id.map { "\"id\":\($0)," } ?? ""
    let dateField = publishedDate.map { "\"publishedDate\":\"\($0)\"," } ?? ""
    let updatedField = lastUpdatedDate.map { "\"lastUpdatedDate\":\"\($0)\"," } ?? ""
    return """
    {
      \(idField)\(dateField)\(updatedField)
      "comments":[{"author":{"id":"\(authorID)"},"commentType":"system"}],
      "properties":{
        "CodeReviewThreadType":{"$type":"System.String","$value":"VoteUpdate"},
        \(voterProperty),
        "CodeReviewVoteResult":{"$type":"System.String","$value":\(value)}
      }\(identitiesField)
    }
    """
}

func reviewCommentThreadJSON(
    author: String = reviewerID, type: String? = "text", deleted: Bool = false,
    content: String = "", threadType: String? = nil
) -> String {
    let typeField = type.map { ",\"commentType\":\"\($0)\"" } ?? ""
    let threadTypeField = threadType.map {
        ",\"CodeReviewThreadType\":{\"$type\":\"System.String\",\"$value\":\"\($0)\"}"
    } ?? ""
    return """
    {
      "comments":[{"author":{"id":"\(author)"}\(typeField),"isDeleted":\(deleted),"content":"\(content)"}],
      "properties":{
        "Microsoft.TeamFoundation.Discussion.SupportsMarkdown":{"$type":"System.Int32","$value":1}\(threadTypeField)
      }
    }
    """
}

actor StubTransport: HTTPTransport {
    private var responses: [HTTPResult]
    private var histories: [Int: HTTPResult]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [HTTPResult], histories: [Int: HTTPResult] = [:]) {
        self.responses = responses
        self.histories = histories
    }

    func setHistory(_ response: HTTPResult, for number: Int) {
        histories[number] = response
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        if let url = request.url, url.path.hasSuffix("/threads") {
            guard let number = url.path.split(separator: "/").dropLast().last.flatMap({ Int($0) }) else {
                throw ReviewQError.invalidResponse("Invalid synthetic review-history URL")
            }
            return histories[number] ?? reviewThreadsResponse()
        }
        guard !responses.isEmpty else { throw ReviewQError.invalidResponse("Unexpected test request") }
        return responses.removeFirst()
    }
}

actor StubAuthorization: AuthorizationProviding {
    private(set) var calls = 0
    private(set) var invalidations = 0

    func authorization(for configuration: ReviewConfiguration) -> String {
        calls += 1
        return "Bearer fixture-\(calls)"
    }

    func invalidate() { invalidations += 1 }
}

struct StubPATStore: PATStoring {
    var token: String? = "synthetic-token"
    var onSave: (@Sendable (String) -> Void)?
    func load() -> String? { token }
    func save(_ token: String) throws {
        _ = try KeychainPATStore.validate(token)
        onSave?(token)
    }
    func remove() {}
}

actor StubCommandRunner: CommandRunning {
    let response: Data
    private(set) var calls: [[String]] = []

    init(_ response: Data) { self.response = response }
    func run(executable: URL, arguments: [String]) -> Data {
        calls.append(arguments)
        return response
    }
}

actor StubReviewLoader: ReviewLoading {
    enum Outcome: Sendable {
        case success(ReviewSnapshot)
        case failure(ReviewQError)
    }

    private var outcomes: [Outcome]
    private(set) var calls = 0

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
    func load(configuration: ReviewConfiguration) throws -> ReviewSnapshot {
        calls += 1
        guard !outcomes.isEmpty else { throw ReviewQError.invalidResponse("Unexpected test refresh") }
        switch outcomes.removeFirst() {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

}

actor DeferredReviewLoader: ReviewLoading {
    private var pending: CheckedContinuation<ReviewSnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ snapshot: ReviewSnapshot) {
        pending?.resume(returning: snapshot)
        pending = nil
    }
}
