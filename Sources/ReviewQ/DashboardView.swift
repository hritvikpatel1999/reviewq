import AppKit
import ReviewQCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: ReviewStore
    @ObservedObject var app: AppDelegate
    @State private var expandedRepositoryIDs: Set<String> = []

    private var groups: [RepositoryGroup] {
        RepositoryGroup.grouping(store.snapshot?.pullRequests ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
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
            if let snapshot = store.snapshot {
                Divider()
                refreshStatus(snapshot)
            }
        }
        .frame(width: 440, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("ReviewQ").font(.headline)
                if let snapshot = store.snapshot {
                    Text("\(snapshot.pullRequests.count) pending reviews").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Your Azure DevOps review queue").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption)
                .help("Quit ReviewQ")
            if store.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 24)
                    .accessibilityLabel("Refreshing pull requests")
            } else {
                Button { store.requestRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!store.configuration.hasSources)
                .help("Refresh reviews")
                .keyboardShortcut("r", modifiers: .command)
            }
            Button { app.showSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings")
                .contextMenu {
                    Button("Diagnostics...") { app.showDiagnostics() }
                }
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
        } else if groups.isEmpty {
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
                            open: { app.open($0.url) }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private func refreshStatus(_ snapshot: ReviewSnapshot) -> some View {
        HStack(spacing: 3) {
            Text(store.errorMessage == nil ? "Updated" : "Last successful update")
            Text(snapshot.updatedAt, style: .relative)
            Text("ago")
            Spacer()
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
        Dictionary(grouping: requests, by: \.groupID).map { group in
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

struct RepositoryDropdown: View {
    let group: RepositoryGroup
    @Binding var isExpanded: Bool
    let open: (ReviewPullRequest) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 6) {
                ForEach(group.requests) { request in
                    PullRequestRow(request: request) { open(request) }
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
                Spacer(minLength: 8)
                Text("\(group.requests.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(group.requests.count) pending pull requests")
            }
        }
        .disclosureGroupStyle(RepositoryDisclosureStyle())
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("repository-dropdown-\(group.id)")
    }
}

private struct RepositoryDisclosureStyle: DisclosureGroupStyle {
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
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide this repository's pull requests")
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct PullRequestRow: View {
    let request: ReviewPullRequest
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if request.isRequired {
                        Text("Required").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    if request.isDraft { Text("Draft").font(.caption2).foregroundStyle(.secondary) }
                    Text(request.reviewStage.label).font(.caption2).foregroundStyle(.secondary)
                        .help(request.reviewStage.explanation)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(request.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack {
                    Text(request.author).lineLimit(1)
                    Spacer()
                    Text(request.createdAt, style: .relative)
                    Text("old")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                isHovered ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Pull request: \(request.title), by \(request.author), \(request.reviewStage.label)")
        .help("Open pull request in your browser")
    }
}
