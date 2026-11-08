import Foundation

struct HTTPResult: Sendable {
    let data: Data
    let status: Int
    var continuationToken: String?
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ReviewQError.invalidResponse("Azure DevOps")
        }
        return HTTPResult(
            data: data, status: response.statusCode,
            continuationToken: response.value(forHTTPHeaderField: "x-ms-continuationtoken")
        )
    }
}

public struct AzureDevOpsReviewLoader: ReviewLoading {
    private let authorization: any AuthorizationProviding
    private let transport: any HTTPTransport
    private let diagnostics: DiagnosticLogger
    private static let pageSize = 100
    private static let historyConcurrency = 4

    public init(keychain: any PATStoring = KeychainPATStore(), diagnostics: DiagnosticLogger = .disabled) {
        authorization = AzureDevOpsCredentials(keychain: keychain, diagnostics: diagnostics)
        transport = URLSessionTransport()
        self.diagnostics = diagnostics
    }

    init(
        authorization: any AuthorizationProviding, transport: any HTTPTransport,
        diagnostics: DiagnosticLogger = .disabled
    ) {
        self.authorization = authorization
        self.transport = transport
        self.diagnostics = diagnostics
    }

    public func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
        let sources = try configuration.validatedSources()
        let header = try await authorization.authorization(for: configuration)
        do {
            return try await fetch(sources: sources, configuration: configuration, header: header)
        } catch let error as ReviewQError {
            if configuration.authentication == .azureCLI, case .http(401, _) = error {
                await authorization.invalidate()
                let renewed = try await authorization.authorization(for: configuration)
                return try await fetch(sources: sources, configuration: configuration, header: renewed)
            }
            throw error
        }
    }

    private func fetch(
        sources: [ReviewSource], configuration: ReviewConfiguration, header: String
    ) async throws -> ReviewSnapshot {
        var identities: [String: UUID] = [:]
        var pullRequests: [String: ReviewPullRequest] = [:]
        for source in sources {
            try Task.checkCancellation()
            let organizationKey = source.organization.lowercased()
            let reviewerID: UUID
            if let cached = identities[organizationKey] {
                reviewerID = cached
            } else {
                let url = try AzureDevOpsURL.make(
                    organization: source.organization, path: ["_apis", "connectionData"],
                    query: [URLQueryItem(name: "api-version", value: "7.1-preview.1")]
                )
                let (connection, _): (APIConnection, HTTPResult) = try await get(
                    url, header: header, source: source.displayName, operation: .identity
                )
                guard connection.authenticatedUser.isActive != false,
                      connection.authenticatedUser.id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                else { throw ReviewQError.http(401, source.displayName) }
                reviewerID = connection.authenticatedUser.id
                identities[organizationKey] = reviewerID
            }
            let projects: [String]
            if let project = source.project {
                projects = [project]
            } else {
                projects = try await projectNames(source: source, header: header)
            }
            for project in projects {
                let reviews = try await pendingReviews(
                    source: source, project: project, reviewerID: reviewerID.uuidString,
                    includeDrafts: configuration.includeDrafts, header: header
                )
                for review in reviews { pullRequests[review.id] = review }
            }
        }
        let sorted = pullRequests.values.sorted(by: ReviewPullRequest.newestFirst)
        return ReviewSnapshot(pullRequests: sorted)
    }

    private func projectNames(source: ReviewSource, header: String) async throws -> [String] {
        var names: [String] = []
        var seenProjects: Set<String> = []
        var seenTokens: Set<String> = []
        var continuation: String?
        repeat {
            try Task.checkCancellation()
            var query = [
                URLQueryItem(name: "api-version", value: "7.1"),
                URLQueryItem(name: "$top", value: String(Self.pageSize))
            ]
            if let continuation {
                query.append(URLQueryItem(name: "continuationToken", value: continuation))
            }
            let url = try AzureDevOpsURL.make(
                organization: source.organization, path: ["_apis", "projects"], query: query
            )
            let (page, response): (APIList<APIProject>, HTTPResult) = try await get(
                url, header: header, source: source.displayName, operation: .projects, page: seenTokens.count + 1
            )
            for project in page.value where seenProjects.insert(project.id.lowercased()).inserted {
                names.append(project.name)
            }
            continuation = response.continuationToken.flatMap { $0.isEmpty ? nil : $0 }
            if let continuation, !seenTokens.insert(continuation).inserted {
                throw ReviewQError.invalidPagination(source.displayName)
            }
        } while continuation != nil
        return names
    }

    private func pendingReviews(
        source: ReviewSource, project: String, reviewerID: String, includeDrafts: Bool, header: String
    ) async throws -> [ReviewPullRequest] {
        let scope = "\(source.organization)/\(project)"
        var reviews: [ReviewPullRequest] = []
        var seenIDs: Set<Int> = []
        var skip = 0
        while true {
            try Task.checkCancellation()
            let url = try AzureDevOpsURL.make(
                organization: source.organization, path: [project, "_apis", "git", "pullrequests"],
                query: [
                    URLQueryItem(name: "api-version", value: "7.1"),
                    URLQueryItem(name: "searchCriteria.status", value: "active"),
                    URLQueryItem(name: "searchCriteria.reviewerId", value: reviewerID),
                    URLQueryItem(name: "$top", value: String(Self.pageSize)),
                    URLQueryItem(name: "$skip", value: String(skip))
                ]
            )
            let (page, _): (APIList<APIPullRequest>, HTTPResult) = try await get(
                url, header: header, source: scope, operation: .pullRequests, page: skip / Self.pageSize + 1
            )
            var newIDs = 0
            var candidates: [(request: APIPullRequest, reviewer: APIReviewer)] = []
            for request in page.value where seenIDs.insert(request.pullRequestId).inserted {
                newIDs += 1
                if let reviewer = request.pendingReviewer(for: reviewerID, includeDrafts: includeDrafts) {
                    candidates.append((request, reviewer))
                }
            }
            reviews += try await reviewsWithHistory(
                candidates, source: source, project: project, reviewerID: reviewerID, header: header
            )
            if page.value.count < Self.pageSize { return reviews }
            guard newIDs > 0 else { throw ReviewQError.invalidPagination(scope) }
            skip += page.value.count
        }
    }

    private func reviewsWithHistory(
        _ candidates: [(request: APIPullRequest, reviewer: APIReviewer)],
        source: ReviewSource, project: String, reviewerID: String, header: String
    ) async throws -> [ReviewPullRequest] {
        guard let identity = UUID(uuidString: reviewerID) else {
            throw ReviewQError.invalidResponse("\(source.organization)/\(project)")
        }
        return try await withThrowingTaskGroup(of: ReviewPullRequest.self) { group in
            var remaining = candidates.makeIterator()
            for _ in 0..<Self.historyConcurrency {
                if let candidate = remaining.next() {
                    group.addTask {
                        try await reviewWithHistory(
                            candidate, source: source, project: project, reviewerID: identity, header: header
                        )
                    }
                }
            }
            var reviews: [ReviewPullRequest] = []
            while let review = try await group.next() {
                reviews.append(review)
                if let candidate = remaining.next() {
                    group.addTask {
                        try await reviewWithHistory(
                            candidate, source: source, project: project, reviewerID: identity, header: header
                        )
                    }
                }
            }
            return reviews
        }
    }

    private func reviewWithHistory(
        _ candidate: (request: APIPullRequest, reviewer: APIReviewer),
        source: ReviewSource, project: String, reviewerID: UUID, header: String
    ) async throws -> ReviewPullRequest {
        try Task.checkCancellation()
        let request = candidate.request
        let scope = "\(source.organization)/\(project)/\(request.repository.name) review history"
        let url = try AzureDevOpsURL.make(
            organization: source.organization,
            path: [
                project, "_apis", "git", "repositories", request.repository.id,
                "pullRequests", String(request.pullRequestId), "threads"
            ],
            query: [URLQueryItem(name: "api-version", value: "7.1")]
        )
        let (threads, response): (APIList<APIReviewThread>, HTTPResult) = try await get(
            url, header: header, source: scope, operation: .reviewHistory
        )
        if let continuation = response.continuationToken, !continuation.isEmpty {
            throw ReviewQError.invalidPagination(scope)
        }
        let stage: ReviewStage = threads.value.contains { $0.hasReviewActivity(from: reviewerID) }
            ? .reReview : .firstReview
        return try request.review(source: source, reviewer: candidate.reviewer, stage: stage)
    }

    private func get<Value: Decodable & Sendable>(
        _ url: URL, header: String, source: String, operation: DiagnosticOperation, page: Int? = nil
    ) async throws -> (Value, HTTPResult) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let requestID = UUID()
        let started = ContinuousClock.now
        diagnostics.log(.debug, .requestStarted, operation: operation, requestID: requestID, page: page)
        var response: HTTPResult?
        do {
            let received = try await transport.send(request)
            response = received
            guard (200..<300).contains(received.status) else {
                throw ReviewQError.http(received.status, source)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let text = try container.decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = formatter.date(from: text) else {
                    throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "Invalid ISO 8601 date."
                    )
                }
                return date
            }
            let value = try decoder.decode(Value.self, from: received.data)
            diagnostics.log(
                .info, .requestFinished, operation: operation, requestID: requestID,
                status: received.status, durationMilliseconds: DiagnosticTiming.milliseconds(since: started),
                responseBytes: received.data.count, page: page
            )
            return (value, received)
        } catch {
            let issue = DiagnosticFailure(error)
            diagnostics.log(
                issue.reason == .cancelled ? .info : .warning,
                issue.reason == .cancelled ? .requestCancelled : .requestFailed,
                operation: operation, requestID: requestID, reason: issue.reason,
                status: response?.status ?? issue.status,
                durationMilliseconds: DiagnosticTiming.milliseconds(since: started),
                responseBytes: response?.data.count, page: page, systemCode: issue.systemCode
            )
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw ReviewQError.network(source, error.localizedDescription, code: error.code.rawValue)
            }
            if error is DecodingError { throw ReviewQError.invalidResponse(source) }
            throw error
        }
    }
}
