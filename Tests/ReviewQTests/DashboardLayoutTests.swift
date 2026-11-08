import AppKit
@testable import ReviewQ
@testable import ReviewQCore
import SwiftUI
import Vision
import XCTest

@MainActor
final class DashboardLayoutTests: XCTestCase {
    func testReviewStagesAreBesideDraftWithoutNumbersOrAnotherRow() throws {
        var heights: Set<Int> = []
        for stage in ReviewStage.allCases {
            for draft in [false, true] {
                let request = fixture(stage: stage, draft: draft, required: true)
                let image = try render(
                    PullRequestRow(
                        request: request, open: {}, openInEdge: {}, review: { _ in }, isLaunchingReview: false
                    )
                        .frame(width: 392)
                )
                heights.insert(image.height)
                let lines = try recognize(image)
                XCTAssertTrue(lines.contains { $0.contains(stage.label) }, "\(lines)")
                if draft {
                    XCTAssertTrue(lines.contains {
                        $0.contains("Draft") && $0.contains(stage.label)
                    }, "Draft and review stage must be on the same line: \(lines)")
                }
                XCTAssertFalse(lines.joined().contains(String(request.number)))
                XCTAssertFalse(lines.joined().contains("#"))
                XCTAssertFalse(lines.contains { $0.split(separator: " ").contains("old") })
            }
        }
        XCTAssertEqual(heights.count, 1, "Review labels must not add height to the PR row")
    }

    func testNewestFirstOrderingHasADeterministicTieBreak() {
        let newest = fixture(number: 20, createdAt: 300)
        let tieA = fixture(number: 7, createdAt: 200)
        let tieB = fixture(number: 8, createdAt: 200)
        for requests in [[tieB, newest, tieA], [tieA, tieB, newest]] {
            let groups = RepositoryGroup.grouping(requests)
            XCTAssertEqual(groups.first?.requests.map(\.number), [20, 7, 8])
        }
        XCTAssertFalse(ReviewPullRequest.newestFirst(tieA, tieA))
    }

    func testDashboardRemovesFooterActionsButKeepsQuitAndRefreshTime() async throws {
        let name = "ReviewQ-layout-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = try makeStore(defaults: defaults)
        await store.refresh()
        let view = DashboardView(store: store, app: AppDelegate(store: store)).frame(width: 440, height: 540)
        let image = try await capture(view)
        let text = try recognize(image).joined(separator: "\n")
        XCTAssertEqual(text.components(separatedBy: "Quit").count - 1, 1, text)
        XCTAssertTrue(text.contains("Updated"))
        XCTAssertFalse(text.contains("Settings..."))
        XCTAssertFalse(text.contains("Azure DevOps"))
    }

    func testDashboardStillIdentifiesTheLastSuccessfulUpdateAfterAnError() async throws {
        let name = "ReviewQ-layout-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = try makeStore(defaults: defaults)
        await store.refresh()
        await store.refresh()
        XCTAssertNotNil(store.errorMessage)
        let view = DashboardView(store: store, app: AppDelegate(store: store)).frame(width: 440, height: 540)
        let image = try await capture(view)
        let text = try recognize(image).joined(separator: "\n")
        XCTAssertTrue(text.contains("Last successful update"), text)
    }

    private func fixture(
        number: Int = 8675309, createdAt: TimeInterval = 1,
        stage: ReviewStage = .firstReview, draft: Bool = false, required: Bool = false
    ) -> ReviewPullRequest {
        ReviewPullRequest(
            number: number, title: "A compact pull request row", author: "A reviewer",
            organization: "example", project: "Project", repository: "Service", repositoryID: "service-id",
            createdAt: Date(timeIntervalSince1970: createdAt),
            url: URL(string: "https://dev.azure.com/example/Project/_git/service/pullrequest/\(number)")!,
            isRequired: required, isDraft: draft, reviewStage: stage
        )
    }

    private func makeStore(defaults: UserDefaults) throws -> ReviewStore {
        let store = ReviewStore(defaults: defaults, keychain: NoPATStore(), loader: LayoutReviewLoader())
        var settings = ReviewConfiguration()
        settings.sourceURLs = "https://dev.azure.com/example/Project"
        try store.save(settings)
        return store
    }

    private func render(_ view: some View) throws -> CGImage {
        _ = NSApplication.shared
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "en_US"))
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 3
        return try XCTUnwrap(renderer.cgImage)
    }

    private func capture(_ view: some View) async throws -> CGImage {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.displayIfNeeded()
        // ImageRenderer omits AppKit-backed borderless toolbar buttons.
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }

    private func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try XCTUnwrap(request.results).map {
            try XCTUnwrap($0.topCandidates(1).first?.string)
        }
    }
}

private struct NoPATStore: PATStoring {
    func load() throws -> String? { throw ReviewQError.missingPAT }
    func save(_ token: String) throws { throw ReviewQError.missingPAT }
    func remove() throws { throw ReviewQError.missingPAT }
}

private actor LayoutReviewLoader: ReviewLoading {
    private var calls = 0

    func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
        calls += 1
        if calls == 1 { return ReviewSnapshot(pullRequests: [], updatedAt: Date().addingTimeInterval(-180)) }
        throw ReviewQError.http(403, "example/Project")
    }
}
