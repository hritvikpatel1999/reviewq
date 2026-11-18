import AppKit
import ReviewQCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: ReviewStore
    @ObservedObject var app: AppDelegate
    @ObservedObject var updates: UpdateStore
    @State private var expandedRepositoryIDs: Set<String> = []
    @State private var isFollowedPeopleExpanded = false
    @State private var isAuthoredExpanded = false
    @State private var isArchiveExpanded = false

    init(store: ReviewStore, app: AppDelegate) {
        self.store = store
        self.app = app
        updates = app.updates
    }

    private var groups: [RepositoryGroup] {
        RepositoryGroup.grouping(store.activePullRequests)
    }

    private var followedRequests: [ReviewPullRequest] {
        store.activePullRequests.filter(\.isFollowedOnly).sorted(by: ReviewPullRequest.newestFirst)
    }

    private var authoredRequests: [ReviewPullRequest] {
        store.activePullRequests.filter { $0.authoredStatus != nil }
            .sorted(by: ReviewPullRequest.newestFirst)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let update = updates.bannerUpdate {
                updateBanner(update)
                Divider()
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.06))
            }
            if let error = store.archiveErrorMessage {
                Label(error, systemImage: "archivebox")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.06))
            }
            queue
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = app.actionError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func updateBanner(_ update: AvailableUpdate) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("ReviewQ v\(update.version) is out")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("View Updates") { app.open(update.releaseURL) }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .fixedSize()
                .help("Open this release on GitHub. Download and install it manually.")
                .accessibilityIdentifier("app-update-link")
            Button { updates.dismissUpdate() } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel("Dismiss update for version \(update.version)")
            .accessibilityIdentifier("app-update-dismiss")
            .help("Hide this version's banner. The next release will appear again.")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update-banner")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ReviewQ").font(.headline)
                if store.snapshot != nil {
                    Text("\(store.pendingReviewCount) pending reviews").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Your Azure DevOps review queue").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Setup") { app.showOnboarding() }
                .font(.caption)
                .foregroundStyle(.tint)
                .fixedSize()
                .help("Run or resume setup. Close Settings first to preserve unsaved edits.")
                .accessibilityIdentifier("dashboard-run-setup")
            if store.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
                    .accessibilityLabel("Refreshing pull requests")
                    .accessibilityIdentifier("dashboard-refresh")
            } else {
                Button { store.requestRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .frame(width: 24, height: 24)
                .disabled(!store.configuration.hasSources)
                .help("Refresh reviews")
                .accessibilityLabel("Refresh reviews")
                .accessibilityIdentifier("dashboard-refresh")
                .keyboardShortcut("r", modifiers: .command)
            }
            Button { app.showSettings() } label: { Image(systemName: "gearshape") }
                .frame(width: 24, height: 24)
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("dashboard-settings")
                .contextMenu {
                    Button("Diagnostics...") { app.showDiagnostics() }
                }
            Divider().frame(height: 16)
            Button { app.quit() } label: {
                Image(systemName: "power")
            }
            .frame(width: 24, height: 24)
            .help("Quit ReviewQ")
            .accessibilityLabel("Quit ReviewQ")
            .accessibilityIdentifier("dashboard-quit")
        }
        .buttonStyle(.borderless)
        .padding(16)
    }

    @ViewBuilder
    private var queue: some View {
        if !store.configuration.hasSources {
            VStack(spacing: 14) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 40)).foregroundStyle(.tint)
                Text("Your next review, one click away").font(.headline)
                Text("Connect Azure DevOps to see pull requests\nwaiting for your review.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Connect Azure DevOps") { app.showSettings() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        } else if store.snapshot == nil {
            VStack(spacing: 12) {
                if store.isRefreshing {
                    ProgressView()
                    Text("Fetching your review queue...").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Could not load reviews").font(.headline)
                    Button("Check Settings") { app.showSettings() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
        } else if groups.isEmpty && !store.configuration.followPeople
                    && !store.configuration.showAuthoredPullRequests && store.archivedPullRequests.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: store.errorMessage == nil ? "checkmark.circle" : "clock.badge.exclamationmark")
                    .font(.system(size: 42))
                    .foregroundStyle(store.errorMessage == nil ? Color.green : Color.orange)
                Text(store.errorMessage == nil ? "You're all caught up" : "Showing the last successful queue")
                    .font(.headline)
                Text(store.errorMessage == nil
                     ? "No unvoted pull requests are assigned to you."
                     : "Refresh again to check for new reviews.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        RepositoryDropdown(
                            group: group,
                            isExpanded: Binding(
                                get: { expandedRepositoryIDs.contains(group.id) },
                                set: { expanded in
                                    if expanded {
                                        expandedRepositoryIDs.insert(group.id)
                                    } else {
                                        expandedRepositoryIDs.remove(group.id)
                                    }
                                }
                            ),
                            open: { app.open($0.url) },
                            openInEdge: { app.openInEdge($0.url) },
                            review: { request, assistant in
                                Task { await app.review(request, with: assistant) }
                            },
                            isLaunchingReview: app.isLaunchingReview,
                            changes: store.changes,
                            archive: store.archive
                        )
                    }
                    if store.configuration.followPeople {
                        FollowedPeopleSection(
                            requests: followedRequests,
                            isExpanded: $isFollowedPeopleExpanded,
                            open: { app.open($0.url) },
                            openInEdge: { app.openInEdge($0.url) },
                            review: { request, assistant in
                                Task { await app.review(request, with: assistant) }
                            },
                            isLaunchingReview: app.isLaunchingReview,
                            changes: store.changes,
                            archive: store.archive
                        )
                    }
                    if store.configuration.showAuthoredPullRequests {
                        AuthoredPullRequestsSection(
                            requests: authoredRequests, isExpanded: $isAuthoredExpanded,
                            open: { app.open($0.url) },
                            openInEdge: { app.openInEdge($0.url) },
                            changes: store.changes,
                            archive: store.archive
                        )
                    }
                    if !store.archivedPullRequests.isEmpty {
                        ArchivedPullRequestsSection(
                            requests: store.archivedPullRequests, isExpanded: $isArchiveExpanded,
                            open: { app.open($0.url) }, restore: store.restore
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 3) {
            if let snapshot = store.snapshot {
                Text(store.errorMessage == nil ? "Updated" : "Last successful update")
                Text(snapshot.updatedAt, style: .relative)
                Text("ago")
            }
            Spacer()
            Button("By: Hritvik Patel") {
                app.openDocumentation("https://github.com/hritvikpatel1999")
            }
                .buttonStyle(.borderless)
                .help("Open Hritvik Patel's GitHub profile")
                .accessibilityIdentifier("dashboard-creator-link")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(14)
    }

}

struct RepositoryGroup: Identifiable {
    let id: String
    let repository: String
    let location: String
    let requests: [ReviewPullRequest]

    static func grouping(_ requests: [ReviewPullRequest]) -> [RepositoryGroup] {
        Dictionary(grouping: requests.filter { !$0.isFollowedOnly && $0.authoredStatus == nil }, by: \.groupID).map { group in
            let repository = group.value[0]
            return RepositoryGroup(
                id: group.key, repository: repository.repository,
                location: "\(repository.organization) / \(repository.project)",
                requests: group.value.sorted(by: ReviewPullRequest.newestFirst)
            )
        }
        .sorted { $0.id < $1.id }
    }
}

struct AuthoredPullRequestsSection: View {
    let requests: [ReviewPullRequest]
    @Binding var isExpanded: Bool
    let open: (ReviewPullRequest) -> Void
    let openInEdge: (ReviewPullRequest) -> Void
    var changes = ReviewChanges()
    var archive: ((ReviewPullRequest) -> Void)? = nil

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                if requests.isEmpty {
                    Text("No active PRs authored by you.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(requests) { request in
                        PullRequestRow(
                            request: request, open: { open(request) },
                            openInEdge: { openInEdge(request) },
                            isChanged: changes.pullRequestIDs.contains(request.id),
                            archiveAction: archive.map { archive in .archive { archive(request) } }
                        )
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Label("I'm the Author", systemImage: "person.crop.circle")
                    .font(.system(size: 13, weight: .semibold))
                if changes.authoredPullRequests { RefreshChangeDot() }
                Spacer(minLength: 8)
                Text("\(requests.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(requests.count) authored pull requests")
            }
        }
        .disclosureGroupStyle(ReviewDisclosureStyle(
            accessibilityHint: "Show or hide pull requests authored by you",
            hasChanges: changes.authoredPullRequests
        ))
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("authored-pull-requests-section")
    }
}

struct FollowedPeopleSection: View {
    let requests: [ReviewPullRequest]
    @Binding var isExpanded: Bool
    let open: (ReviewPullRequest) -> Void
    let openInEdge: (ReviewPullRequest) -> Void
    let review: (ReviewPullRequest, ReviewAssistant) -> Void
    let isLaunchingReview: Bool
    var changes = ReviewChanges()
    var archive: ((ReviewPullRequest) -> Void)? = nil

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                if requests.isEmpty {
                    Text("No other active PRs from people you follow.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(requests) { request in
                        PullRequestRow(
                            request: request, open: { open(request) },
                            openInEdge: { openInEdge(request) },
                            review: { review(request, $0) }, isLaunchingReview: isLaunchingReview,
                            isChanged: changes.pullRequestIDs.contains(request.id),
                            archiveAction: archive.map { archive in .archive { archive(request) } }
                        )
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Label("People you follow", systemImage: "person.2")
                    .font(.system(size: 13, weight: .semibold))
                if changes.followedPeople { RefreshChangeDot() }
                Spacer(minLength: 8)
                Text("\(requests.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(requests.count) followed pull requests")
            }
        }
        .disclosureGroupStyle(ReviewDisclosureStyle(
            accessibilityHint: "Show or hide pull requests from people you follow",
            hasChanges: changes.followedPeople
        ))
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("followed-people-section")
    }
}

struct RepositoryDropdown: View {
    let group: RepositoryGroup
    @Binding var isExpanded: Bool
    let open: (ReviewPullRequest) -> Void
    let openInEdge: (ReviewPullRequest) -> Void
    let review: (ReviewPullRequest, ReviewAssistant) -> Void
    let isLaunchingReview: Bool
    var changes = ReviewChanges()
    var archive: ((ReviewPullRequest) -> Void)? = nil

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                ForEach(group.requests) { request in
                    PullRequestRow(
                        request: request, open: { open(request) },
                        openInEdge: { openInEdge(request) },
                        review: { review(request, $0) }, isLaunchingReview: isLaunchingReview,
                        isChanged: changes.pullRequestIDs.contains(request.id),
                        archiveAction: archive.map { archive in .archive { archive(request) } }
                    )
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.repository).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(group.location).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if changes.repositoryIDs.contains(group.id) { RefreshChangeDot() }
                Spacer(minLength: 8)
                Text("\(group.requests.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(group.requests.count) pending pull requests")
            }
        }
        .disclosureGroupStyle(ReviewDisclosureStyle(
            accessibilityHint: "Show or hide this repository's pull requests",
            hasChanges: changes.repositoryIDs.contains(group.id)
        ))
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("repository-dropdown-\(group.id)")
    }
}

struct ArchivedPullRequestsSection: View {
    let requests: [ReviewPullRequest]
    @Binding var isExpanded: Bool
    let open: (ReviewPullRequest) -> Void
    let restore: (ReviewPullRequest) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                ForEach(requests) { request in
                    PullRequestRow(
                        request: request, open: { open(request) },
                        archiveAction: .restore { restore(request) }
                    )
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Label("Archives", systemImage: "archivebox")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(requests.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(requests.count) archived pull requests")
            }
        }
        .disclosureGroupStyle(ReviewDisclosureStyle(
            accessibilityHint: "Show or hide archived pull requests. Restore a PR to return it to its active list."
        ))
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("archived-pull-requests-section")
    }
}

private struct ReviewDisclosureStyle: DisclosureGroupStyle {
    let accessibilityHint: String
    var hasChanges = false

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                (configuration.isExpanded ? "Expanded" : "Collapsed")
                    + (hasChanges ? ", changed since previous successful refresh" : "")
            )
            .accessibilityHint(accessibilityHint)
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct RefreshChangeDot: View {
    var body: some View {
        Circle().fill(Color(nsColor: .systemGreen))
            .frame(width: 6, height: 6)
            .help("Changed since the previous successful refresh")
            .accessibilityHidden(true)
    }
}

struct PullRequestRow: View {
    let request: ReviewPullRequest
    let open: () -> Void
    let isChanged: Bool
    private let actions: Actions
    private let archiveAction: ArchiveAction?
    @State private var isHovered = false

    private enum Actions {
        case browser
        case edge(() -> Void)
        case review(openInEdge: () -> Void, review: (ReviewAssistant) -> Void, isLaunching: Bool)
    }

    enum ArchiveAction {
        case archive(() -> Void), restore(() -> Void)

        var isRestoring: Bool {
            if case .restore = self { return true }
            return false
        }

        func perform() {
            switch self {
            case .archive(let action), .restore(let action): action()
            }
        }
    }

    private var authorLabel: String {
        archiveAction?.isRestoring == true ? "\(request.author) in \(request.repository)" : request.authorLabel
    }

    private var actionSpace: CGFloat {
        let count = switch actions {
        case .browser, .edge: 1
        case .review: 3
        }
        return CGFloat((count + (archiveAction == nil ? 0 : 1)) * 28)
    }

    init(
        request: ReviewPullRequest, open: @escaping () -> Void, openInEdge: (() -> Void)? = nil,
        isChanged: Bool = false,
        archiveAction: ArchiveAction? = nil
    ) {
        self.request = request
        self.open = open
        self.isChanged = isChanged
        self.archiveAction = archiveAction
        actions = openInEdge.map { .edge($0) } ?? .browser
    }

    init(
        request: ReviewPullRequest, open: @escaping () -> Void, openInEdge: @escaping () -> Void,
        review: @escaping (ReviewAssistant) -> Void, isLaunchingReview: Bool, isChanged: Bool = false,
        archiveAction: ArchiveAction? = nil
    ) {
        self.request = request
        self.open = open
        self.isChanged = isChanged
        self.archiveAction = archiveAction
        actions = request.authoredStatus == nil
            ? .review(openInEdge: openInEdge, review: review, isLaunching: isLaunchingReview) : .edge(openInEdge)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        if isChanged { RefreshChangeDot() }
                        if request.isRequired {
                            Text("Required").font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if request.isDraft {
                            Text("Draft").font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if request.authoredStatus != nil {
                            if let label = request.authoredStatusLabel {
                                Text(label).font(.caption2)
                                    .foregroundStyle(request.isMergeReady ? Color.green : Color.secondary)
                                    .lineLimit(1).minimumScaleFactor(0.85)
                                    .help(request.authoredStatusExplanation)
                            }
                        } else {
                            Text(request.reviewStageLabel).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.85)
                                .help(request.reviewStageExplanation)
                        }
                        Spacer(minLength: actionSpace)
                    }
                    .frame(height: 22)
                    Text(request.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack {
                        Text(authorLabel).lineLimit(1).help(authorLabel)
                        Spacer()
                        Text(request.createdAt, style: .relative)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Pull request: \(request.title), by \(authorLabel)"
                    + (request.authoredStatus == nil
                       ? ", \(request.reviewStageLabel)" : request.authoredStatusLabel.map { ", \($0)" } ?? "")
                    + (isChanged ? ", changed since previous successful refresh" : "")
            )
            .help("Open pull request in your browser")

            HStack(spacing: 6) {
                if let archiveAction {
                    Button(action: archiveAction.perform) {
                        Image(systemName: archiveAction.isRestoring ? "arrow.uturn.backward" : "archivebox.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(archiveAction.isRestoring ? Color.blue.gradient : Color.orange.gradient)
                            .frame(width: 18, height: 18)
                            .background(.white, in: RoundedRectangle(cornerRadius: 4))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(archiveAction.isRestoring ? "Restore" : "Archive") pull request: \(request.title)")
                    .accessibilityIdentifier("\(archiveAction.isRestoring ? "restore" : "archive")-pr-\(request.id)")
                    .help(archiveAction.isRestoring
                          ? "Restore PR to its active list"
                          : "Move PR to Archives in ReviewQ only")
                }
                switch actions {
                case .browser:
                    Button(action: open) {
                        Image(systemName: "globe")
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Open in browser: \(request.title)")
                    .help("Open PR in your browser")
                case .edge(let openInEdge):
                    edgeButton(action: openInEdge)
                case .review(let openInEdge, let review, let isLaunching):
                    edgeButton(action: openInEdge)
                    ForEach(ReviewAssistant.allCases, id: \.self) { assistant in
                        Button { review(assistant) } label: {
                            ReviewAssistantIcon(assistant: assistant)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .disabled(isLaunching)
                        .accessibilityLabel("Review with \(assistant.name): \(request.title)")
                        .help("Review with \(assistant.name)")
                    }
                }
            }
            .buttonStyle(PRIconButtonStyle())
            .padding(10)
        }
        .background(
            isHovered ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .onHover { isHovered = $0 }
    }

    private func edgeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            EdgeBrowserIcon().frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .accessibilityLabel("Open in Microsoft Edge: \(request.title)")
        .help("Open PR in Microsoft Edge")
    }
}

struct PRIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration)
    }

    private struct Feedback: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .modifier(PRIconAffordance(isHovered: isHovered, isPressed: configuration.isPressed))
                .onHover { isHovered = $0 }
        }
    }
}

struct PRIconAffordance: ViewModifier {
    let isHovered: Bool
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlighted: Bool { isEnabled && (isHovered || isPressed) }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isEnabled && isHovered ? 1.15 : 1)
            .frame(width: 22, height: 22)
            .background(
                Color.accentColor.opacity(highlighted ? 0.18 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(highlighted ? 0.3 : 0), lineWidth: 1)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: highlighted)
    }
}

private struct EdgeBrowserIcon: View {
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac") {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit().frame(width: 20, height: 20)
        } else {
            Image(systemName: "globe").font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }
}

private struct ReviewAssistantIcon: View {
    let assistant: ReviewAssistant

    var body: some View {
        if let url = assistant.applicationURL {
            if assistant == .copilot,
               let image = NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/app/extensions/copilot/assets/copilot.png")) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit().frame(width: 20, height: 20)
            }
        } else {
            Image(systemName: assistant == .scout ? "safari" : "sparkles")
                .font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }
}
