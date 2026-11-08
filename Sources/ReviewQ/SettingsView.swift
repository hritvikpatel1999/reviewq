import ReviewQCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ReviewStore
    @ObservedObject var app: AppDelegate
    @ObservedObject var loginItem: LoginItemStore
    @State private var draft: ReviewConfiguration
    @State private var token = ""
    @State private var formError: String?
    @State private var didSave = false
    @State private var confirmDeletePAT = false

    init(store: ReviewStore, app: AppDelegate, loginItem: LoginItemStore) {
        self.store = store
        self.app = app
        self.loginItem = loginItem
        _draft = State(initialValue: store.configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 30)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Azure DevOps reviews").font(.title2.weight(.semibold))
                            Text("A quiet home for your next pull request.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    sources
                    authentication
                    preferences
                    startup
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if let error = app.actionError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Button("Diagnostics...") { app.showDiagnostics() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                VStack(alignment: .leading, spacing: 4) {
                    if let formError {
                        Text(formError).font(.caption).foregroundStyle(.red)
                    } else if store.isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Refreshing reviews...").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if didSave {
                        Text("Settings saved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Save and Refresh", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 540)
        .onChange(of: draft) { _, _ in
            didSave = false
            formError = nil
        }
        .confirmationDialog("Delete the saved Azure DevOps PAT?", isPresented: $confirmDeletePAT) {
            Button("Delete saved PAT", role: .destructive) {
                do {
                    try store.deleteSavedPAT()
                    token = ""
                    formError = nil
                } catch { formError = error.localizedDescription }
            }
        } message: {
            Text("If PAT authentication is active, reviews stop loading until you save a new token.")
        }
    }

    private var sources: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("One organization or project URL per line.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.sourceURLs)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 82)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if draft.sourceURLs.isEmpty {
                            Text("https://dev.azure.com/your-organization/your-project")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary).padding(11)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Azure DevOps source URLs")
                Text("Organization-only URLs search all accessible projects. Project URLs are faster for large organizations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Review sources", systemImage: "building.2") }
    }

    private var authentication: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Authentication", selection: $draft.authentication) {
                    Text("Azure CLI").tag(AuthenticationMethod.azureCLI)
                    Text("Personal access token").tag(AuthenticationMethod.personalAccessToken)
                }
                .pickerStyle(.segmented).labelsHidden()
                if draft.authentication == .azureCLI {
                    Text("Sign in once in Terminal; ReviewQ uses short-lived Entra tokens.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("az login --allow-no-subscriptions")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    TextField("Tenant ID or domain (optional)", text: $draft.tenantID)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave the tenant blank to use your current Azure CLI account.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Azure CLI setup instructions") {
                        app.openDocumentation("https://learn.microsoft.com/azure/devops/cli/entra-tokens")
                    }
                    .buttonStyle(.link)
                } else {
                    SecureField("Paste a Code (Read) PAT", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: token) { _, _ in formError = nil; didSave = false }
                    Text("Stored in macOS Keychain, never in settings. Leave blank to retain the saved PAT.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Organization-wide discovery also needs Project and Team (Read). The PAT must cover every source.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("How to create a PAT") {
                        app.openDocumentation(
                            "https://learn.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate"
                        )
                    }
                    .buttonStyle(.link)
                }
                Button("Delete saved PAT", role: .destructive) { confirmDeletePAT = true }
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Authentication", systemImage: "key") }
    }

    private var preferences: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Refresh", selection: $draft.refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                Toggle("Show pending count in the menu bar", isOn: $draft.showCount)
                Toggle("Include draft pull requests", isOn: $draft.includeDrafts)
                Text("Only active, directly assigned PRs with no vote from you are shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Review queue", systemImage: "line.3.horizontal.decrease.circle") }
    }

    private var startup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch ReviewQ at login", isOn: Binding(
                    get: { loginItem.isOn },
                    set: { value in Task { await loginItem.setEnabled(value) } }
                ))
                .disabled(loginItem.isWorking || loginItem.status == .notFound)
                Text(loginItem.statusMessage).font(.caption).foregroundStyle(.secondary)
                if loginItem.status == .requiresApproval {
                    Button("Open Login Items") { loginItem.openSystemSettings() }
                }
                if let error = loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: { Label("Startup", systemImage: "power") }
    }

    private func save() {
        do {
            try store.save(draft, newPAT: token)
            token = ""
            formError = nil
            didSave = true
        } catch {
            formError = error.localizedDescription
            didSave = false
        }
    }
}
