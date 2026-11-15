import CryptoKit
import Foundation
import OSLog

@MainActor
final class ReviewQueueCache {
    static let settingsKey = "reviewQueueCache"
    static let maximumBytes = 2 * 1_048_576
    static let maximumRequests = 4_096
    static let lifetime: TimeInterval = 7 * 24 * 3_600

    private struct Storage: Codable {
        let version: Int
        let configurationScope: String
        let snapshot: ReviewSnapshot
    }

    private struct Options: Encodable {
        let sources: [String]
        let authentication: AuthenticationMethod
        let tenant: String
        let includeDrafts: Bool
        let followedAuthors: [String]
        let showAuthored: Bool
    }

    private let defaults: UserDefaults
    private let diagnostics: DiagnosticLogger
    private let clock: () -> Date
    private let logger = Logger(subsystem: "dev.prbar.app", category: "queue-cache")

    init(
        defaults: UserDefaults, diagnostics: DiagnosticLogger = .disabled,
        clock: @escaping () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.diagnostics = diagnostics
        self.clock = clock
    }

    func load(configuration: ReviewConfiguration, identityScope: String) -> ReviewSnapshot? {
        guard defaults.object(forKey: Self.settingsKey) != nil else { return nil }
        do {
            guard let data = defaults.data(forKey: Self.settingsKey), data.count <= Self.maximumBytes else {
                throw QueueCacheError.invalidData
            }
            let storage = try JSONDecoder().decode(Storage.self, from: data)
            guard storage.version == 1, Self.isScope(storage.configurationScope) else {
                throw QueueCacheError.invalidData
            }
            guard storage.configurationScope == (try configurationScope(configuration)),
                  storage.snapshot.identityScope == identityScope else {
                clear(reason: .superseded)
                return nil
            }
            try validate(storage.snapshot, configuration: configuration)
            let age = clock().timeIntervalSince(storage.snapshot.updatedAt)
            guard age >= 0, age < Self.lifetime else {
                clear(reason: .retention)
                return nil
            }
            diagnostics.log(.info, .queueCacheRestored, operation: .queueCache, count: storage.snapshot.pullRequests.count)
            return storage.snapshot
        } catch {
            defaults.removeObject(forKey: Self.settingsKey)
            diagnostics.log(.warning, .queueCacheInvalidated, operation: .queueCache, reason: .decoding)
            logger.warning("The stored review queue was invalid and has been cleared.")
            return nil
        }
    }

    func save(_ snapshot: ReviewSnapshot, configuration: ReviewConfiguration) {
        do {
            try validate(snapshot, configuration: configuration)
            let data = try JSONEncoder().encode(Storage(
                version: 1, configurationScope: configurationScope(configuration), snapshot: snapshot
            ))
            guard data.count <= Self.maximumBytes else { throw QueueCacheError.tooLarge }
            defaults.set(data, forKey: Self.settingsKey)
        } catch {
            defaults.removeObject(forKey: Self.settingsKey)
            diagnostics.logFailure(.queueCacheWriteFailed, error: error, operation: .queueCache)
            logger.warning("The successful review queue could not be cached. Check ReviewQ Diagnostics.")
        }
    }

    func clear(reason: DiagnosticReason = .superseded) {
        defaults.removeObject(forKey: Self.settingsKey)
        diagnostics.log(.info, .queueCacheCleared, operation: .queueCache, reason: reason)
    }

    private func configurationScope(_ configuration: ReviewConfiguration) throws -> String {
        let options = Options(
            sources: try configuration.validatedSources().map(\.id).sorted(),
            authentication: configuration.authentication,
            tenant: configuration.tenantID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            includeDrafts: configuration.includeDrafts,
            followedAuthors: try configuration.validatedFollowedAuthors().sorted(),
            showAuthored: configuration.showAuthoredPullRequests
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(options)).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ snapshot: ReviewSnapshot, configuration: ReviewConfiguration) throws {
        guard let scope = snapshot.identityScope, Self.isScope(scope),
              snapshot.updatedAt.timeIntervalSince1970.isFinite,
              snapshot.pullRequests.count <= Self.maximumRequests,
              Set(snapshot.pullRequests.map(\.id)).count == snapshot.pullRequests.count else {
            throw QueueCacheError.invalidData
        }
        let organizations = Set(try configuration.validatedSources().map { $0.organization.lowercased() })
        for request in snapshot.pullRequests {
            let expectedURL = try AzureDevOpsURL.make(
                organization: request.organization,
                path: [request.project, "_git", request.repositoryID, "pullrequest", String(request.number)]
            )
            guard request.number > 0, organizations.contains(request.organization.lowercased()),
                  !request.project.isEmpty, !request.repositoryID.isEmpty, request.url == expectedURL,
                  request.createdAt.timeIntervalSince1970.isFinite,
                  request.changeFingerprint.map({ $0.count == 32 }) ?? true,
                  request.commentResolution.map({ $0.resolvedCount >= 0 && $0.openCount >= 0 }) ?? true,
                  request.authoredStatus.map({ $0.activeCommentCount >= 0 }) ?? true,
                  !request.isDraft || configuration.includeDrafts,
                  !request.isFollowedOnly || configuration.followPeople,
                  request.authoredStatus == nil || configuration.showAuthoredPullRequests,
                  !(request.isFollowedOnly && request.authoredStatus != nil) else {
                throw QueueCacheError.invalidData
            }
        }
    }

    private static func isScope(_ scope: String) -> Bool {
        scope.utf8.count == 64 && scope.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

private enum QueueCacheError: LocalizedError {
    case invalidData, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidData: "The local review queue cache was invalid and has been cleared."
        case .tooLarge: "The review queue exceeds the local cache budget and will not be restored after restarting."
        }
    }
}
