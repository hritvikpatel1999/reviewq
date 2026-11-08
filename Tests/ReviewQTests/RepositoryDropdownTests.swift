import AppKit
@testable import ReviewQ
@testable import ReviewQCore
import SwiftUI
import XCTest

@MainActor
final class RepositoryDropdownTests: XCTestCase {
    func testRepositoryGroupsHaveSeparateCountsAndLocations() throws {
        let first = try request(number: 1)
        let second = try request(number: 2)
        let otherOrganization = try request(number: 3, organization: "another")
        let otherRepository = try request(number: 4, repository: "Other")
        let groups = RepositoryGroup.grouping([first, second, otherOrganization, otherRepository])
        XCTAssertEqual(groups.count, 3)
        let service = try XCTUnwrap(groups.first { $0.id == first.groupID })
        XCTAssertEqual(service.repository, "Service")
        XCTAssertEqual(service.location, "example / Project")
        XCTAssertEqual(service.requests.map(\.number), [2, 1])
        XCTAssertEqual(groups.map(\.id), groups.map(\.id).sorted())
        XCTAssertTrue(RepositoryGroup.grouping([]).isEmpty)
    }

    func testDropdownStartsCollapsedAndHeaderTogglesItsReviews() async throws {
        let state = DropdownState()
        let group = try XCTUnwrap(RepositoryGroup.grouping([
            request(number: 1), request(number: 2)
        ]).first)
        let (host, window) = makeHost(group: group, state: state)
        defer { window.close() }
        try await settle(host)
        let collapsedHeight = host.intrinsicContentSize.height
        XCTAssertGreaterThan(collapsedHeight, 0)
        XCTAssertFalse(state.isExpanded)

        try click(headerCenter(in: host, collapsedHeight: collapsedHeight), in: host, window: window)
        try await settle(host)
        XCTAssertTrue(state.isExpanded)
        let expandedHeight = host.intrinsicContentSize.height
        XCTAssertGreaterThan(expandedHeight, collapsedHeight + 100)
        let rowHeight = (expandedHeight - collapsedHeight - 10 - 6) / 2
        let header = headerCenter(in: host, collapsedHeight: collapsedHeight)
        let direction: CGFloat = host.isFlipped ? 1 : -1
        let firstReview = NSPoint(
            x: header.x, y: header.y + direction * (collapsedHeight / 2 - 12 + 10 + rowHeight / 2)
        )
        try click(firstReview, in: host, window: window)
        try await settle(host)
        XCTAssertEqual(state.openedRequest, group.requests.first?.id)

        try click(headerCenter(in: host, collapsedHeight: collapsedHeight), in: host, window: window)
        try await settle(host)
        XCTAssertFalse(state.isExpanded)
        XCTAssertEqual(host.intrinsicContentSize.height, collapsedHeight, accuracy: 1)
    }

    func testExpandedRepositoryRetainsStateAndUpdatesItsCountAfterRefresh() async throws {
        let state = DropdownState()
        let original = try XCTUnwrap(RepositoryGroup.grouping([request(number: 1)]).first)
        let (host, window) = makeHost(group: original, state: state)
        defer { window.close() }
        try await settle(host)
        let collapsedHeight = host.intrinsicContentSize.height
        try click(headerCenter(in: host, collapsedHeight: collapsedHeight), in: host, window: window)
        try await settle(host)
        XCTAssertTrue(state.isExpanded)
        let originalHeight = host.intrinsicContentSize.height

        let refreshed = try XCTUnwrap(RepositoryGroup.grouping([
            request(number: 1), request(number: 2), request(number: 3)
        ]).first)
        host.rootView = DropdownHarness(group: refreshed, state: state)
        try await settle(host)
        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(refreshed.requests.count, 3)
        XCTAssertGreaterThan(host.intrinsicContentSize.height, originalHeight + 100)
    }

    private func request(
        number: Int, organization: String = "example", repository: String = "Service"
    ) throws -> ReviewPullRequest {
        ReviewPullRequest(
            number: number, title: "Synthetic review \(number)", author: "Fixture author",
            organization: organization, project: "Project",
            repository: repository, repositoryID: repository.lowercased(),
            createdAt: Date(timeIntervalSince1970: TimeInterval(number)),
            url: try XCTUnwrap(URL(string: "https://dev.azure.com/\(organization)/Project/_git/repo/pullrequest/\(number)")),
            isRequired: false, isDraft: false, reviewStage: .firstReview
        )
    }

    private func makeHost(
        group: RepositoryGroup, state: DropdownState
    ) -> (NSHostingView<DropdownHarness>, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: DropdownHarness(group: group, state: state))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (host, window)
    }

    private func settle(_ host: NSView) async throws {
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
    }

    private func headerCenter(in host: NSView, collapsedHeight: CGFloat) -> NSPoint {
        let direction: CGFloat = host.isFlipped ? -1 : 1
        return NSPoint(
            x: host.bounds.midX,
            y: host.bounds.midY + direction * (host.intrinsicContentSize.height - collapsedHeight) / 2
        )
    }

    private func click(_ point: NSPoint, in host: NSView, window: NSWindow) throws {
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            NSApplication.shared.postEvent(event, atStart: false)
        }
        while let event = NSApplication.shared.nextEvent(
            matching: [.leftMouseDown, .leftMouseUp], until: Date().addingTimeInterval(0.05),
            inMode: .default, dequeue: true
        ) {
            window.sendEvent(event)
        }
    }
}

@MainActor
private final class DropdownState: ObservableObject {
    @Published var isExpanded = false
    var openedRequest: String?
}

private struct DropdownHarness: View {
    let group: RepositoryGroup
    @ObservedObject var state: DropdownState

    var body: some View {
        RepositoryDropdown(group: group, isExpanded: $state.isExpanded) {
            state.openedRequest = $0.id
        }
        .frame(width: 416)
    }
}
