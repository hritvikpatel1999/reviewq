import Foundation

public enum ReviewStage: String, Sendable {
    case firstReview
    case reReview

    public var label: String {
        switch self {
        case .firstReview: "First Review"
        case .reReview: "Re-review"
        }
    }

    public var explanation: String {
        switch self {
        case .firstReview: "No previous vote or review comment from you was found."
        case .reReview: "You have already voted or left a review comment on this pull request."
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
    let comments: [APIReviewComment]
    let properties: APIReviewThreadProperties?
    let voterID: UUID?

    private enum CodingKeys: String, CodingKey {
        case comments, properties, identities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

    func hasReviewActivity(from reviewerID: UUID) -> Bool {
        if voterID == reviewerID, let vote = properties?.vote, vote != 0 { return true }
        return comments.contains {
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
        }
    }
}

private struct APIProperty<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value

    private enum CodingKeys: String, CodingKey {
        case value = "$value"
    }
}
