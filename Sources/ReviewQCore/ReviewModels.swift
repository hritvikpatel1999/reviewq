import Foundation

public enum ReviewStage: String, CaseIterable, Sendable {
    case firstReview
    case approved, approvedWithSuggestions, waitedForAuthor, rejected, commented

    public var label: String {
        switch self {
        case .firstReview: "First Review"
        case .approved: "You Approved"
        case .approvedWithSuggestions: "You Approved with Suggestions"
        case .waitedForAuthor: "You Waited for Author"
        case .rejected: "You Rejected"
        case .commented: "You Commented"
        }
    }

    public var explanation: String {
        switch self {
        case .firstReview: "No previous nonzero vote or review comment from you was found."
        case .approved: "Your last recorded nonzero vote was Approved. This PR needs your vote again."
        case .approvedWithSuggestions:
            "Your last recorded nonzero vote was Approved with suggestions. This PR needs your vote again."
        case .waitedForAuthor:
            "Your last recorded nonzero vote was Waiting for author. This PR needs your vote again."
        case .rejected: "Your last recorded nonzero vote was Rejected. This PR needs your vote again."
        case .commented: "You previously left a review comment, but no nonzero vote from you was found."
        }
    }

    static func fromHistory(_ threads: [APIReviewThread], reviewerID: UUID) throws -> Self {
        let votes = threads.compactMap { thread -> (thread: APIReviewThread, vote: Int)? in
            guard thread.voterID == reviewerID, let vote = thread.properties?.vote, vote != 0 else { return nil }
            return (thread, vote)
        }
        guard let first = votes.first else {
            return threads.contains { $0.hasReviewComment(from: reviewerID) } ? .commented : .firstReview
        }
        if Set(votes.map(\.vote)).count == 1 { return try fromVote(first.vote) }
        guard votes.allSatisfy({ $0.thread.publishedDate != nil }),
              let newestDate = votes.compactMap({ $0.thread.publishedDate }).max() else {
            throw ReviewQError.invalidResponse("Azure DevOps review-history chronology")
        }
        let newest = votes.filter { $0.thread.publishedDate == newestDate }
        if let first = newest.first, Set(newest.map(\.vote)).count == 1 { return try fromVote(first.vote) }
        let identifiers = newest.compactMap { $0.thread.id }
        guard identifiers.count == newest.count, Set(identifiers).count == newest.count,
              let latest = zip(identifiers, newest).max(by: { $0.0 < $1.0 }) else {
            throw ReviewQError.invalidResponse("Azure DevOps review-history chronology")
        }
        return try fromVote(latest.1.vote)
    }

    private static func fromVote(_ vote: Int) throws -> Self {
        switch vote {
        case 10: .approved
        case 5: .approvedWithSuggestions
        case -5: .waitedForAuthor
        case -10: .rejected
        default: throw ReviewQError.invalidResponse("Azure DevOps review vote")
        }
    }
}

public struct ReviewPullRequest: Equatable, Sendable, Identifiable {
    public let number: Int
    public let title: String
    public let author: String
    public let organization: String
    public let project: String
    public let repository: String
    public let repositoryID: String
    public let createdAt: Date
    public let url: URL
    public let isRequired: Bool
    public let isDraft: Bool
    public let reviewStage: ReviewStage

    public var id: String { "\(organization.lowercased())/\(repositoryID.lowercased())/\(number)" }
    public var groupID: String { "\(organization)/\(project)/\(repository)" }

    public static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }
}

public struct ReviewSnapshot: Equatable, Sendable {
    public let pullRequests: [ReviewPullRequest]
    public let updatedAt: Date

    public init(pullRequests: [ReviewPullRequest], updatedAt: Date = Date()) {
        self.pullRequests = pullRequests
        self.updatedAt = updatedAt
    }
}

public protocol ReviewLoading: Sendable {
    func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot
}

struct APIList<Item: Decodable & Sendable>: Decodable, Sendable {
    let value: [Item]
}

struct APIProject: Decodable, Sendable {
    let id: String
    let name: String
}

struct APIConnection: Decodable, Sendable {
    let authenticatedUser: APIConnectionIdentity
}

struct APIConnectionIdentity: Decodable, Sendable {
    let id: UUID
    let isActive: Bool?
}

struct APIIdentity: Decodable, Sendable {
    let id: String
    let displayName: String
}

struct APIReviewer: Decodable, Sendable {
    let id: String
    let vote: Int
    let isRequired: Bool?
    let hasDeclined: Bool?
}

struct APIRepository: Decodable, Sendable {
    let id: String
    let name: String
    let project: APIProject
}

struct APIPullRequest: Decodable, Sendable {
    let pullRequestId: Int
    let title: String
    let status: String
    let creationDate: Date
    let createdBy: APIIdentity
    let repository: APIRepository
    let reviewers: [APIReviewer]
    let isDraft: Bool?

    func pendingReviewer(for reviewerID: String, includeDrafts: Bool) -> APIReviewer? {
        guard status.lowercased() == "active",
              includeDrafts || isDraft != true,
              createdBy.id.caseInsensitiveCompare(reviewerID) != .orderedSame,
              let reviewer = reviewers.first(where: {
                  $0.id.caseInsensitiveCompare(reviewerID) == .orderedSame
              }),
              reviewer.vote == 0, reviewer.hasDeclined != true else { return nil }
        return reviewer
    }

    func review(source: ReviewSource, reviewer: APIReviewer, stage: ReviewStage) throws -> ReviewPullRequest {
        let url = try AzureDevOpsURL.make(
            organization: source.organization,
            path: [repository.project.name, "_git", repository.id, "pullrequest", String(pullRequestId)]
        )
        return ReviewPullRequest(
            number: pullRequestId, title: title, author: createdBy.displayName,
            organization: source.organization, project: repository.project.name,
            repository: repository.name, repositoryID: repository.id,
            createdAt: creationDate, url: url,
            isRequired: reviewer.isRequired == true, isDraft: isDraft == true, reviewStage: stage
        )
    }
}

struct APIReviewThread: Decodable, Sendable {
    let id: Int?
    let publishedDate: Date?
    let comments: [APIReviewComment]
    let properties: APIReviewThreadProperties?
    let voterID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, publishedDate, comments, properties, identities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        publishedDate = try container.decodeIfPresent(Date.self, forKey: .publishedDate)
        comments = try container.decode([APIReviewComment].self, forKey: .comments)
        properties = try container.decodeIfPresent(APIReviewThreadProperties.self, forKey: .properties)
        if let directID = properties?.voterID {
            voterID = directID
        } else if let reference = properties?.voterReference, properties?.vote != 0 {
            let identities = try container.decode([String: APIReviewComment.Author].self, forKey: .identities)
            guard let identity = identities[reference] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .identities, in: container, debugDescription: "Unresolved voting identity."
                )
            }
            voterID = identity.id
        } else {
            voterID = nil
        }
    }

    func hasReviewComment(from reviewerID: UUID) -> Bool {
        comments.contains {
            $0.author.id == reviewerID
                && $0.isReviewComment(inSystemThread: properties?.isSystemThread == true)
        }
    }
}

struct APIReviewComment: Decodable, Sendable {
    let author: Author
    let commentType: String?
    let isDeleted: Bool
    let hasContent: Bool

    private enum CodingKeys: String, CodingKey {
        case author, commentType, isDeleted, content
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        author = try container.decode(Author.self, forKey: .author)
        commentType = try container.decodeIfPresent(String.self, forKey: .commentType)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        let content = try container.decodeIfPresent(String.self, forKey: .content)
        hasContent = content?.contains { !$0.isWhitespace } == true
    }

    func isReviewComment(inSystemThread: Bool) -> Bool {
        let type = commentType?.lowercased()
        if type == "text" { return true }
        guard type == nil || type == "unknown", !inSystemThread else { return false }
        // Older discussion comments can omit the type without losing their authorship.
        return hasContent || isDeleted
    }

    struct Author: Decodable, Sendable {
        let id: UUID
    }
}

struct APIReviewThreadProperties: Decodable, Sendable {
    let voterID: UUID?
    let voterReference: String?
    let vote: Int?
    let isSystemThread: Bool

    private enum CodingKeys: String, CodingKey {
        case threadType = "CodeReviewThreadType"
        case voterID = "CodeReviewVotedByTfId"
        case voterReference = "CodeReviewVotedByIdentity"
        case vote = "CodeReviewVoteResult"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(APIProperty<String>.self, forKey: .threadType)?.value
        isSystemThread = type?.isEmpty == false
        if type?.lowercased() == "voteupdate" {
            voterID = try container.decodeIfPresent(APIProperty<UUID>.self, forKey: .voterID)?.value
            voterReference = try container.decodeIfPresent(APIProperty<String>.self, forKey: .voterReference)?.value
            vote = try container.decode(APIProperty<VoteValue>.self, forKey: .vote).value.value
            guard vote == 0 || voterID != nil || voterReference != nil else {
                throw DecodingError.keyNotFound(CodingKeys.voterID, .init(
                    codingPath: decoder.codingPath, debugDescription: "Missing voting identity."
                ))
            }
        } else {
            voterID = nil
            voterReference = nil
            vote = nil
        }
    }

    private struct VoteValue: Decodable, Sendable {
        let value: Int

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                value = number
            } else {
                let text = try container.decode(String.self)
                guard let number = Int(text) else {
                    throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "Invalid review vote."
                    )
                }
                value = number
            }
            guard [-10, -5, 0, 5, 10].contains(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unsupported review vote."
                )
            }
        }
    }
}

private struct APIProperty<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value

    private enum CodingKeys: String, CodingKey {
        case value = "$value"
    }
}
