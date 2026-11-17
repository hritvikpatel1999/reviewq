import Foundation
@testable import ReviewQCore
import XCTest

final class UpdateClientTests: XCTestCase {
    func testStableReleaseUsesOnePublicRequestAndNeverSendsCredentials() async throws {
        let transport = StubTransport([try response(tag: "v3.1.10", headers: ["etag": "\"release-one\""])])
        let result = try await GitHubUpdateClient(transport: transport).check(entityTag: nil)
        let release = try AvailableUpdate(
            version: "3.1.10", releaseURL: XCTUnwrap(URL(string: releaseURL("v3.1.10")))
        )
        XCTAssertEqual(result, .modified(release: release, entityTag: "\"release-one\""))
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/hritvikpatel1999/reviewq/releases/latest")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testConditionalResponseRequiresAnExistingValidator() async throws {
        let transport = StubTransport([
            HTTPResult(data: Data(), status: 304), HTTPResult(data: Data(), status: 304)
        ])
        let client = GitHubUpdateClient(transport: transport)
        let result = try await client.check(entityTag: "W/\"cached\"")
        XCTAssertEqual(result, .notModified)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "W/\"cached\"")
        do {
            _ = try await client.check(entityTag: nil)
            XCTFail("An uncached 304 must not be reported as a successful check.")
        } catch { XCTAssertEqual(DiagnosticFailure(error).reason, .invalidResponse) }
    }

    func testDraftsAndPrereleasesAreNotOffered() async throws {
        for (draft, prerelease) in [(true, false), (false, true)] {
            let transport = StubTransport([try response(tag: "v4.0.0-beta.1", draft: draft, prerelease: prerelease)])
            let result = try await GitHubUpdateClient(transport: transport).check(entityTag: nil)
            XCTAssertEqual(result, .modified(release: nil, entityTag: nil))
        }
    }

    func testMalformedVersionsPayloadsAndUntrustedLinksFailExplicitly() async throws {
        var responses = try ["3.1", "3.01.0", "3.1.2-beta", "3.1.-1", "3.1.99999999999999999999999999"].map {
            try response(tag: $0)
        }
        for url in [
            "http://github.com/hritvikpatel1999/reviewq/releases/tag/v3.1.2",
            "https://github.com.example.com/hritvikpatel1999/reviewq/releases/tag/v3.1.2",
            "https://github.com/other/repo/releases/tag/v3.1.2",
            releaseURL("v3.1.3"), releaseURL("v3.1.2") + "?redirect=elsewhere"
        ] {
            responses.append(try response(tag: "v3.1.2", url: url))
        }
        responses.append(HTTPResult(data: Data("broken JSON".utf8), status: 200))
        responses.append(HTTPResult(data: Data(repeating: 32, count: 512 * 1_024 + 1), status: 200))
        responses.append(try response(tag: "v3.1.2", headers: ["etag": "unsafe\r\nheader"]))
        for response in responses {
            do {
                _ = try await GitHubUpdateClient(transport: StubTransport([response])).check(entityTag: nil)
                XCTFail("Invalid release data must not produce an update or an up-to-date result.")
            } catch {
                XCTAssertTrue([DiagnosticReason.invalidResponse, .decoding].contains(DiagnosticFailure(error).reason))
            }
        }
    }

    func testRateLimitAndRetryHeadersSetTheLatestRequiredDeadline() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(7_200)
        let cases: [(Int, [String: String], Date, DiagnosticReason)] = [
            (429, ["retry-after": "120"], now.addingTimeInterval(120), .rateLimited),
            (403, ["retry-after": "120"], now.addingTimeInterval(120), .rateLimited),
            (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(Int(reset.timeIntervalSince1970))",
                   "retry-after": "120"], reset, .rateLimited),
            (503, ["retry-after": "Fri, 15 Jan 2027 08:02:00 GMT"], now.addingTimeInterval(120), .serviceUnavailable),
            (429, [:], now.addingTimeInterval(3_600), .rateLimited)
        ]
        for (status, headers, deadline, reason) in cases {
            let client = GitHubUpdateClient(
                transport: StubTransport([HTTPResult(data: Data(), status: status, headers: headers)]), clock: { now }
            )
            do {
                _ = try await client.check(entityTag: nil)
                XCTFail("An HTTP failure is not an up-to-date result.")
            } catch let error as UpdateCheckError {
                guard case .http(let code, let retryAt, _) = error else { return XCTFail("Expected HTTP failure") }
                XCTAssertEqual(code, status)
                XCTAssertEqual(retryAt, deadline)
                XCTAssertEqual(DiagnosticFailure(error).reason, reason)
            }
        }
    }

    private func response(
        tag: String, url: String? = nil, draft: Bool = false, prerelease: Bool = false, headers: [String: String] = [:]
    ) throws -> HTTPResult {
        HTTPResult(data: try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": url ?? releaseURL(tag), "draft": draft, "prerelease": prerelease
        ]), status: 200, headers: headers)
    }

    private func releaseURL(_ tag: String) -> String {
        "https://github.com/hritvikpatel1999/reviewq/releases/tag/\(tag)"
    }
}
