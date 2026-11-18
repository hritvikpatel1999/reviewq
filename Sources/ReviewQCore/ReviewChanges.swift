import CryptoKit
import Foundation

public struct ReviewChanges: Equatable, Sendable {
    public private(set) var pullRequestIDs: Set<String> = []
    public private(set) var repositoryIDs: Set<String> = []
    public private(set) var followedPeople = false
    public private(set) var authoredPullRequests = false

    public init() {}

    public var hasChanges: Bool {
        !pullRequestIDs.isEmpty || !repositoryIDs.isEmpty || followedPeople || authoredPullRequests
    }

    init(previous: ReviewSnapshot?, current: ReviewSnapshot, excluding archivedIDs: Set<String> = []) {
        guard let previous, previous.identityScope == current.identityScope else { return }
        var remaining = Dictionary(uniqueKeysWithValues: previous.pullRequests
            .filter { !archivedIDs.contains($0.id) }.map { ($0.id, $0) })
        for request in current.pullRequests where !archivedIDs.contains(request.id) {
            let old = remaining.removeValue(forKey: request.id)
            guard old != request else { continue }
            pullRequestIDs.insert(request.id)
            markSection(for: request)
            if let old { markSection(for: old) }
        }
        for removed in remaining.values { markSection(for: removed) }
    }

    private mutating func markSection(for request: ReviewPullRequest) {
        if request.authoredStatus != nil {
            authoredPullRequests = true
        } else if request.isFollowedOnly {
            followedPeople = true
        } else {
            repositoryIDs.insert(request.groupID)
        }
    }
}

enum ReviewFingerprint {
    private struct Input: Encodable {
        let fields: [String]
        let children: [Data]
    }

    static func make(_ fields: [String], children: [Data] = []) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let input = Input(fields: fields, children: children.sorted { $0.lexicographicallyPrecedes($1) })
        return Data(SHA256.hash(data: try encoder.encode(input)))
    }

    static func pullRequest(_ request: APIPullRequest, threads: [APIReviewThread]) throws -> Data {
        let reviewers = try request.reviewers.map {
            try make([
                "reviewer", $0.id.lowercased(), String($0.vote),
                String($0.isRequired == true), String($0.hasDeclined == true)
            ])
        }
        return try make([
            "pull-request", request.sourceRefName ?? "", request.targetRefName ?? "",
            request.lastMergeSourceCommit?.commitId.lowercased() ?? ""
        ], children: reviewers + threads.map(\.fingerprint))
    }
}
