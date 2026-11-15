import ReviewQCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingStore
    @ObservedObject var app: AppDelegate
    @ObservedObject private var loginItem: LoginItemStore
    @ObservedObject private var menuShortcut: GlobalShortcutStore

    init(model: OnboardingStore, app: AppDelegate) {
        self.model = model
        self.app = app
        loginItem = app.loginItem
        menuShortcut = app.menuShortcut
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.horizontal, 30).padding(.top, 22).padding(.bottom, 8)
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 26) {
                        VStack(spacing: 10) {
                            Text(model.step.title)
                                .font(.system(size: 27, weight: .semibold, design: .rounded))
                                .accessibilityAddTraits(.isHeader)
                            Text(model.step.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        page
                        messages
                    }
                    .frame(maxWidth: 650)
                    .padding(.horizontal, 36).padding(.vertical, 30)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                .id(model.step)
            }
            footer.padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 24)
        }
        .frame(minWidth: 720, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshCompanions()
        }
        .onAppear { loginItem.refresh(); model.refreshCompanions() }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(step.rawValue < model.step.rawValue ? 0.6 : 0.2))
                    .frame(width: step == model.step ? 30 : 15, height: 4)
            }
            Spacer()
            Text("ReviewQ").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count): \(model.step.title)")
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: welcome
        case .sources: sources
        case .authentication: authentication
        case .companions: companions
        case .preferences: preferences
        case .ready: ready
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            card {
                HStack {
                    Label("Example queue", systemImage: "arrow.triangle.pull")
                        .font(.headline)
                    Spacer()
                    Text("2 to review").font(.caption).foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 6)
                HStack(spacing: 12) {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Service").font(.callout.weight(.semibold))
                        Text("example / Project").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("2").font(.caption.weight(.semibold))
                }
                ForEach(["Improve request validation", "Handle retries reliably"], id: \.self) { title in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("First Review").font(.caption2).foregroundStyle(.secondary)
                        Text(title).font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityLabel("Example queue preview, not live pull requests")
            Text("Grouped by repository. Newest first. One click to review.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var sources: some View {
        card {
            Label("Review sources", systemImage: "building.2").font(.headline)
            Text("One organization or project URL per line.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $model.draft.sourceURLs)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 110).padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if model.draft.sourceURLs.isEmpty {
                        Text("https://dev.azure.com/your-organization/your-project")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary).padding(13).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Azure DevOps source URLs")
                .accessibilityIdentifier("setup-source-urls")
            Text("A project URL keeps discovery focused and is faster for large organizations. An organization-only URL searches all accessible projects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var authentication: some View {
        card {
            Picker("Authentication", selection: $model.draft.authentication) {
                Text("Azure CLI - recommended").tag(AuthenticationMethod.azureCLI)
                Text("Personal access token").tag(AuthenticationMethod.personalAccessToken)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("setup-authentication")
            if model.draft.authentication == .azureCLI {
                Text("Sign in once in Terminal. ReviewQ uses short-lived Microsoft Entra tokens.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(OnboardingStore.loginCommand).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        if !pasteboard.setString(OnboardingStore.loginCommand, forType: .string) {
                            model.reportActionError("Could not copy the sign-in command. Select and copy the command above.")
                        }
                    }
                    .accessibilityLabel("Copy Azure CLI sign-in command")
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                TextField("Tenant ID or domain (optional)", text: $model.draft.tenantID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Azure tenant ID or domain, optional")
                Button("Install Azure CLI or get sign-in help") {
                    app.openDocumentation("https://learn.microsoft.com/azure/devops/cli/entra-tokens")
                }
                .buttonStyle(.link)
            } else {
                SecureField("Paste a Code (Read) PAT", text: $model.token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Azure DevOps personal access token")
                    .accessibilityIdentifier("setup-pat")
                Text("Your PAT stays in memory while testing. It is saved only to macOS Keychain when you finish. Leave blank to use an existing saved PAT.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Organization-wide discovery also needs Project and Team (Read). The PAT must cover every source.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("How to create a read-only PAT") {
                    app.openDocumentation(
                        "https://learn.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate"
                    )
                }
                .buttonStyle(.link)
            }
            Divider().padding(.vertical, 4)
            HStack {
                if model.isChecking {
                    ProgressView().controlSize(.small)
                    Text("Checking your sources and loading reviews...").font(.caption).foregroundStyle(.secondary)
                } else if model.hasVerifiedAccount {
                    Label("Connected. Your review queue loaded successfully.", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Spacer(minLength: 8)
                Button(model.hasVerifiedAccount ? "Test again" : "Test connection") {
                    Task { await model.testConnection() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("setup-test-connection")
            }
        }
        .disabled(model.isChecking)
    }

    private var companions: some View {
        VStack(spacing: 16) {
            card {
                statusRow(
                    "VS Code", icon: "chevron.left.forwardslash.chevron.right",
                    detail: "Opens a new Copilot Agent chat. Sign in to Copilot inside VS Code.",
                    status: model.companions.copilotInstalled ? "Detected" : "Not installed",
                    positive: model.companions.copilotInstalled
                )
                Divider().padding(.vertical, 5)
                statusRow(
                    "Scout", icon: "sparkles",
                    detail: "Accessibility lets ReviewQ enter your PR review prompt in Scout.",
                    status: !model.companions.scoutInstalled ? "Not installed"
                        : model.companions.scoutAccessibilityAllowed ? "Allowed" : "Needs permission",
                    positive: model.companions.scoutInstalled && model.companions.scoutAccessibilityAllowed
                )
                if model.companions.scoutInstalled, !model.companions.scoutAccessibilityAllowed {
                    Button("Allow Scout automation...") { app.requestScoutAccessibility() }
                        .buttonStyle(.bordered).padding(.leading, 64)
                }
                Divider().padding(.vertical, 5)
                statusRow(
                    "Microsoft Edge", icon: "globe",
                    detail: "An optional browser shortcut. PR cards always open in your default browser.",
                    status: model.companions.edgeInstalled ? "Detected" : "Optional",
                    positive: model.companions.edgeInstalled
                )
            }
            VStack(spacing: 8) {
                Text("VS Code uses your profile's default permissions. Autopilot and Allow All are optional choices you make in VS Code; ReviewQ does not change them.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("VS Code permissions and Autopilot guide") {
                    app.openDocumentation("https://code.visualstudio.com/docs/agents/run/approvals")
                }
                .buttonStyle(.link).font(.caption)
                Text("No microphone or Screen Recording access is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var preferences: some View {
        card {
            HStack {
                Label("Refresh", systemImage: "arrow.clockwise")
                Spacer()
                Picker("Refresh interval", selection: $model.draft.refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden().frame(width: 175)
            }
            Toggle("Show pending count in the menu bar", isOn: $model.draft.showCount)
            Toggle("Include draft pull requests", isOn: $model.draft.includeDrafts)
            Divider().padding(.vertical, 4)
            Toggle("People you follow", isOn: $model.draft.followPeople)
                .accessibilityIdentifier("setup-follow-people")
            if model.draft.followPeople {
                TextField("alex@example.com;sam@example.com", text: $model.draft.followedAuthorEmails)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Followed author emails, separated by semicolons without spaces")
                Text("Use semicolons with no spaces. Adds organization-wide reads; PATs need Identity (Read) and Project and Team (Read). Emails are sent only to Azure DevOps to find the authors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("I'm the Author", isOn: $model.draft.showAuthoredPullRequests)
                .accessibilityIdentifier("setup-authored-prs")
            if model.draft.showAuthoredPullRequests {
                Text("Shows your active PRs, comment counts, and required approvals, not build status. Adds organization-wide reads; PATs need Project and Team (Read).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Both extra sections are off by default. Enabling them adds read-only Azure DevOps requests.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Toggle("Launch ReviewQ at login", isOn: Binding(
                get: { loginItem.isOn },
                set: { enabled in Task { await loginItem.setEnabled(enabled) } }
            ))
            .disabled(loginItem.isWorking || loginItem.status == .notFound)
            Text(loginItem.statusMessage).font(.caption).foregroundStyle(.secondary)
            if loginItem.status == .requiresApproval {
                Button("Open Login Items") { loginItem.openSystemSettings() }.buttonStyle(.link)
            }
            if let error = loginItem.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(model.isChecking)
    }

    private var ready: some View {
        VStack(spacing: 18) {
            if let snapshot = model.snapshot {
                card {
                    statusRow(
                        "Azure DevOps connected", icon: "checkmark.shield",
                        detail: "All configured sources were checked. Refresh: \(model.draft.refreshInterval.label.lowercased()).",
                        status: "Connected", positive: true
                    )
                    Divider().padding(.vertical, 5)
                    statusRow(
                        snapshot.pendingReviewCount == 0 ? "You're caught up" : "\(snapshot.pendingReviewCount) PRs need your review",
                        icon: "arrow.triangle.pull",
                        detail: "Expand a repository to see its PRs, newest first.",
                        status: nil, positive: true
                    )
                    Divider().padding(.vertical, 5)
                    statusRow(
                        "Find ReviewQ in your menu bar", icon: "menubar.rectangle",
                        detail: "Click the pull-request icon near your clock, or press Command-Option-Q.",
                        status: nil, positive: true
                    )
                    if let error = menuShortcut.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Retry shortcut") { app.startMenuShortcut() }.buttonStyle(.link)
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                RefreshChangeDot().padding(.top, 5)
                Text("Green means changed since the previous successful refresh, not unread. Opening a PR does not clear its dot; an unchanged refresh does.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Your choices are saved when you open the queue. Advanced prompts and other controls stay in Settings.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let message = model.infoMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        if let error = model.errorMessage ?? app.actionError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red).multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .accessibilityIdentifier("setup-error")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.step != .welcome {
                Button("Back") { model.back() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(model.isChecking)
                    .accessibilityIdentifier("setup-back")
            }
            if model.canKeepExistingSettings {
                Button("Keep existing settings") {
                    model.keepExistingSettings()
                    app.finishOnboarding()
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isChecking {
                ProgressView().controlSize(.small)
                Text("Loading reviews...").font(.caption).foregroundStyle(.secondary)
            }
            if model.step == .companions {
                Button("Skip for now") { Task { await model.advance() } }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("setup-skip")
            }
            Button(model.primaryButtonTitle) {
                if model.step == .ready {
                    if model.complete() { app.finishOnboarding() }
                } else {
                    Task { await model.advance() }
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canContinue || loginItem.isWorking)
            .accessibilityIdentifier("setup-continue")
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
    }

    private func statusRow(
        _ title: String, icon: String, detail: String, status: String?, positive: Bool
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 21)).foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let status {
                Label(status, systemImage: positive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(positive ? Color.green : Color.secondary)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
