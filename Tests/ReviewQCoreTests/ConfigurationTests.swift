import Foundation
@testable import ReviewQCore
import XCTest

final class ConfigurationTests: XCTestCase {
    func testModernAndLegacySourcesNormalize() throws {
        let modern = try ReviewSource.parse("https://dev.azure.com/example/Project%20Name/")
        let legacy = try ReviewSource.parse("https://example.visualstudio.com/DefaultCollection/Project%20Name")
        XCTAssertEqual(modern, legacy)
        XCTAssertEqual(modern.project, "Project Name")
        XCTAssertEqual(try modern.webURL().absoluteString, "https://dev.azure.com/example/Project%20Name")
        XCTAssertNil(try ReviewSource.parse("https://dev.azure.com/example").project)
    }

    func testUnsafeAndUnsupportedSourcesAreRejected() {
        for value in [
            "http://dev.azure.com/example/Project",
            "https://dev.azure.com.evil.test/example/Project",
            "https://evil.test/example/Project",
            "https://dev.azure.com",
            "https://user:password@dev.azure.com/example/Project",
            "https://dev.azure.com:8443/example/Project",
            "https://dev.azure.com/example/Project?_a=review",
            "https://dev.azure.com/example/Project#fragment",
            "https://dev.azure.com/example/Project/_git/Repository",
            "https://example.other.visualstudio.com/Project",
            "https://dev.azure.com/example/..",
            "https://dev.azure.com/example/%2E%2E",
            "https://dev.azure.com/example/_pulls",
            "https://dev.azure.com/example/Project%0AName",
            "https://dev.azure.com/example/Project%5CName"
        ] {
            XCTAssertThrowsError(try ReviewSource.parse(value), value)
        }
    }

    func testDuplicateSourcesAndMissingSourcesAreExplicitErrors() {
        XCTAssertThrowsError(try configuration(" \n ").validatedSources())
        XCTAssertThrowsError(try configuration("""
        https://dev.azure.com/example/Project
        https://EXAMPLE.visualstudio.com/DefaultCollection/project
        """).validatedSources())
    }

    func testMultipleSourcesAndTenantValidation() throws {
        var settings = configuration("""
        https://dev.azure.com/example/Project

        https://dev.azure.com/another
        """)
        settings.tenantID = "example.onmicrosoft.com"
        XCTAssertEqual(try settings.validatedSources().count, 2)
        settings.tenantID = "--help; echo bad"
        XCTAssertThrowsError(try settings.validatedSources())
        settings.tenantID = reviewerID
        XCTAssertEqual(try settings.validatedSources().count, 2)
    }

    func testPATValidationDoesNotAcceptHeadersOrWhitespace() throws {
        XCTAssertEqual(try KeychainPATStore.validate(" synthetic-token\n"), "synthetic-token")
        for value in ["", "Basic token", "Bearer token", "abc\ndef", "abc\tdef", "abc\u{0}def"] {
            XCTAssertThrowsError(try KeychainPATStore.validate(value), value)
        }
    }

    func testConfigurationNeverContainsPAT() throws {
        var settings = configuration()
        settings.authentication = .personalAccessToken
        let encoded = try JSONEncoder().encode(settings)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("synthetic-token"))
        XCTAssertEqual(try JSONDecoder().decode(ReviewConfiguration.self, from: encoded), settings)
    }
}
