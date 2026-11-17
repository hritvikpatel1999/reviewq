import Foundation

struct ReleaseVersion: Comparable, Sendable {
    private let components: [Int]

    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw UpdateCheckError.invalidVersion }
        components = try parts.map { part in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else {
                throw UpdateCheckError.invalidVersion
            }
            return number
        }
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct AvailableUpdate: Codable, Equatable, Sendable {
    public let version: String
    public let releaseURL: URL

    public init(version: String, releaseURL: URL) throws {
        let parsed: ReleaseVersion
        do {
            parsed = try ReleaseVersion(version)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
        let base = "https://github.com/hritvikpatel1999/reviewq/releases/tag/"
        guard releaseURL.absoluteString == base + parsed.description
                || releaseURL.absoluteString == base + "v" + parsed.description else {
            throw UpdateCheckError.invalidResponse
        }
        self.version = parsed.description
        self.releaseURL = releaseURL
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case modified(release: AvailableUpdate?, entityTag: String?)
    case notModified
}

public protocol UpdateChecking: Sendable {
    func check(entityTag: String?) async throws -> UpdateCheckResult
}

public struct GitHubUpdateClient: UpdateChecking {
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date

    public init() {
        transport = URLSessionTransport(serviceName: "GitHub Releases")
        clock = { .now }
    }

    init(transport: any HTTPTransport, clock: @escaping @Sendable () -> Date = { .now }) {
        self.transport = transport
        self.clock = clock
    }

    public func check(entityTag: String?) async throws -> UpdateCheckResult {
        guard let url = URL(string: "https://api.github.com/repos/hritvikpatel1999/reviewq/releases/latest") else {
            throw UpdateCheckError.invalidResponse
        }
        if let entityTag, !Self.validEntityTag(entityTag) { throw UpdateCheckError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ReviewQ-update-check", forHTTPHeaderField: "User-Agent")
        request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        let result = try await transport.send(request)
        try Task.checkCancellation()
        if result.status == 304 {
            guard entityTag != nil else { throw UpdateCheckError.invalidResponse }
            return .notModified
        }
        guard result.status == 200 else {
            let limited = result.status == 429
                || (result.status == 403 && (result.headers["x-ratelimit-remaining"] == "0"
                    || result.headers["retry-after"] != nil))
            throw UpdateCheckError.http(
                result.status, retryAt: retryDate(result, limited: limited), rateLimited: limited
            )
        }
        guard result.data.count <= 512 * 1_024 else { throw UpdateCheckError.invalidResponse }
        let payload = try JSONDecoder().decode(ReleasePayload.self, from: result.data)
        let tag = result.headers["etag"]
        if let tag, !Self.validEntityTag(tag) { throw UpdateCheckError.invalidResponse }
        guard !payload.draft, !payload.prerelease else { return .modified(release: nil, entityTag: tag) }
        let release = try AvailableUpdate(version: payload.tag_name, releaseURL: payload.html_url)
        return .modified(release: release, entityTag: tag)
    }

    static func validEntityTag(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private func retryDate(_ result: HTTPResult, limited: Bool) -> Date? {
        let now = clock()
        var dates: [Date] = []
        if let value = result.headers["retry-after"] {
            if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
                dates.append(now.addingTimeInterval(seconds))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: value) { dates.append(date) }
            }
        }
        if limited, let value = result.headers["x-ratelimit-reset"],
           let seconds = TimeInterval(value), seconds.isFinite {
            dates.append(Date(timeIntervalSince1970: seconds))
        }
        if let date = dates.filter({ $0 > now }).max() { return date }
        return limited ? now.addingTimeInterval(3_600) : nil
    }
}

private struct ReleasePayload: Decodable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
}

enum UpdateCheckError: LocalizedError, Sendable {
    case invalidVersion, invalidResponse, invalidCache
    case http(Int, retryAt: Date?, rateLimited: Bool)

    var diagnosticReason: DiagnosticReason {
        switch self {
        case .invalidVersion: .invalidConfiguration
        case .invalidResponse: .invalidResponse
        case .invalidCache: .decoding
        case .http(_, _, true): .rateLimited
        case .http(403, _, false): .forbidden
        case .http(404, _, false): .notFound
        case .http(500..<600, _, false): .serviceUnavailable
        case .http: .http
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            "This build has no valid app version. Use a packaged ReviewQ app to check for updates."
        case .invalidResponse:
            "GitHub returned invalid update information. Try checking for updates again later."
        case .invalidCache:
            "Saved update information was invalid and has been cleared. Check for updates again."
        case .http(_, _, true):
            "GitHub temporarily limited update checks. Please try again later."
        case .http(let status, _, false):
            "Could not check for ReviewQ updates (GitHub HTTP \(status)). Try again later."
        }
    }
}
