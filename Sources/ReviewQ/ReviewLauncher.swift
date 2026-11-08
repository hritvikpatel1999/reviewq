import AppKit
import ApplicationServices
import ReviewQCore

enum ReviewAssistant: String, CaseIterable, Sendable {
    case scout, copilot

    var name: String { self == .scout ? "Scout" : "Copilot" }
    var bundleIdentifier: String { self == .scout ? "com.microsoft.clawpilot" : "com.microsoft.VSCode" }
    var diagnosticOperation: DiagnosticOperation { self == .scout ? .scout : .copilot }

    @MainActor
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

enum ReviewLaunchError: LocalizedError, Equatable {
    case invalidURL, appUnavailable(ReviewAssistant), unsupportedCopilotCLI
    case accessibilityRequired, scoutNotReady, scoutDraftChanged, scoutControlUnavailable
    case submissionUnconfirmed, launchFailed, commandTimedOut, commandFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "This pull request does not have a valid HTTPS link."
        case .appUnavailable(let assistant):
            assistant == .scout
                ? "Install Microsoft Scout on this Mac, then try again."
                : "Install Visual Studio Code with Copilot signed in, then try again."
        case .unsupportedCopilotCLI:
            "This VS Code installation does not support new agent chats. Update VS Code and try again."
        case .accessibilityRequired:
            "Allow ReviewQ in System Settings > Privacy & Security > Accessibility, then click Scout again."
        case .scoutNotReady:
            "Scout's new-chat controls are not ready. Finish signing in or dismiss any dialog in Scout, then try again."
        case .scoutDraftChanged:
            "Scout's draft or focus changed. Nothing was submitted. Check Scout before trying again."
        case .scoutControlUnavailable:
            "Scout's chat controls could not be operated safely. Check Scout or update it, then try again."
        case .submissionUnconfirmed:
            "The Scout Send button was clicked, but submission could not be confirmed. Check Scout before retrying."
        case .launchFailed:
            "The review session could not be started. Check that the selected app opens normally and try again."
        case .commandTimedOut:
            "VS Code did not respond in time. Check VS Code before trying again."
        case .commandFailed(let code):
            "VS Code could not start the Copilot chat (exit \(code)). Open VS Code, check Copilot sign-in, and try again."
        }
    }

    var diagnosticReason: DiagnosticReason {
        switch self {
        case .invalidURL: .invalidConfiguration
        case .appUnavailable, .unsupportedCopilotCLI: .cliUnavailable
        case .accessibilityRequired: .approvalPending
        case .scoutNotReady, .commandTimedOut: .timeout
        case .commandFailed: .cliFailure
        default: .system
        }
    }
}

@MainActor
protocol ReviewLaunching {
    func launch(_ assistant: ReviewAssistant, for url: URL) async throws
}

@MainActor
struct ReviewLauncher: ReviewLaunching {
    let applicationURL: (ReviewAssistant) -> URL?
    let runner: any CommandRunning
    let scoutLaunch: (URL, String) async throws -> Void

    init(
        applicationURL: @escaping (ReviewAssistant) -> URL? = { $0.applicationURL },
        runner: any CommandRunning = LocalCommandRunner(timeout: 15, environment: copilotEnvironment()),
        scoutLaunch: @escaping (URL, String) async throws -> Void = { url, prompt in
            try await ScoutReviewAutomation.start(at: url, prompt: prompt)
        }
    ) {
        self.applicationURL = applicationURL
        self.runner = runner
        self.scoutLaunch = scoutLaunch
    }

    static func prompt(for url: URL) throws -> String {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 2_048,
              !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ReviewLaunchError.invalidURL }
        return "Review PR: \(url.absoluteString)"
    }

    static func copilotArguments(prompt: String) -> [String] {
        ["chat", "--mode", "agent", "--new-window", "--maximize", prompt]
    }

    static func copilotEnvironment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        for key in ["VSCODE_IPC_HOOK_CLI", "NODE_OPTIONS", "NODE_REPL_EXTERNAL_MODULE"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + (inherited["PATH"] ?? "")
        return environment
    }

    func launch(_ assistant: ReviewAssistant, for url: URL) async throws {
        try Task.checkCancellation()
        let prompt = try Self.prompt(for: url)
        guard let appURL = applicationURL(assistant) else {
            throw ReviewLaunchError.appUnavailable(assistant)
        }
        switch assistant {
        case .scout:
            try await scoutLaunch(appURL, prompt)
        case .copilot:
            let executable = appURL.appendingPathComponent("Contents/Resources/app/bin/code")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ReviewLaunchError.unsupportedCopilotCLI
            }
            let help = try await runner.run(executable: executable, arguments: ["chat", "--help"])
            guard let text = String(data: help, encoding: .utf8),
                  text.contains("--new-window"), text.contains("--mode"), text.contains("[prompt]")
            else { throw ReviewLaunchError.unsupportedCopilotCLI }
            try Task.checkCancellation()
            _ = try await runner.run(executable: executable, arguments: Self.copilotArguments(prompt: prompt))
        }
    }
}

@MainActor
private struct ScoutReviewAutomation {
    private struct Controls {
        var newChat: [AXUIElement] = []
        var editors: [AXUIElement] = []
        var send: [AXUIElement] = []
        var isRunning = false
        var hasUserMessages = false
    }

    let application: NSRunningApplication
    let root: AXUIElement

    static func start(at url: URL, prompt: String) async throws {
        // The SDK exposes this immutable Accessibility key as a mutable C global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { throw ReviewLaunchError.accessibilityRequired }
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: ReviewLaunchError.launchFailed) }
            }
        }
        guard app.bundleIdentifier == ReviewAssistant.scout.bundleIdentifier else {
            throw ReviewLaunchError.launchFailed
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementSetMessagingTimeout(root, 1) == .success,
              AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        else { throw ReviewLaunchError.scoutControlUnavailable }
        let automation = Self(application: app, root: root)
        try await automation.start(prompt: prompt)
    }

    private func start(prompt: String) async throws {
        let initial = try await wait { $0.newChat.count == 1 && enabled($0.newChat[0]) }
        try press(initial.newChat[0])
        let fresh = try await wait {
            $0.editors.count == 1 && enabled($0.editors[0]) && !$0.hasUserMessages && !$0.isRunning
                && value($0.editors[0]) == ""
        }
        let editor = fresh.editors[0]
        guard application.activate(options: [.activateAllWindows]),
              AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        else { throw ReviewLaunchError.scoutControlUnavailable }
        try await Task.sleep(for: .milliseconds(100))
        var cursor = prompt.startIndex
        var typed = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while cursor < prompt.endIndex {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline, focused(editor), value(editor) == typed else {
                throw ReviewLaunchError.scoutDraftChanged
            }
            let end = prompt.index(cursor, offsetBy: 16, limitedBy: prompt.endIndex) ?? prompt.endIndex
            let chunk = String(prompt[cursor..<end])
            let characters = Array(chunk.utf16)
            // Target Scout's PID, not the global keyboard; never use the user's clipboard.
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
                    throw ReviewLaunchError.scoutControlUnavailable
                }
                event.flags = []
                characters.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                }
                event.postToPid(application.processIdentifier)
            }
            typed += chunk
            _ = try await wait(timeout: 2) { _ in value(editor) == typed }
            cursor = end
        }
        let ready = try await wait {
            $0.send.count == 1 && enabled($0.send[0]) && value(editor) == prompt && focused(editor)
        }
        try press(ready.send[0])
        do {
            _ = try await wait(timeout: 6) {
                $0.editors.count == 1 && value($0.editors[0]) == "" && ($0.isRunning || $0.hasUserMessages)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReviewLaunchError.submissionUnconfirmed
        }
    }

    private func wait(timeout: TimeInterval = 15, until predicate: (Controls) -> Bool) async throws -> Controls {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            try Task.checkCancellation()
            let state = try controls()
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ReviewLaunchError.scoutNotReady
    }

    private func controls() throws -> Controls {
        var state = Controls()
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) throws {
            guard depth < 40, visited < 8_000 else { throw ReviewLaunchError.scoutControlUnavailable }
            visited += 1
            switch text(element, kAXRoleAttribute) {
            case kAXButtonRole:
                let labels = [text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute)]
                if labels.contains("New chat") { state.newChat.append(element) }
                if labels.contains("Send") { state.send.append(element) }
                if labels.contains("Stop") { state.isRunning = true }
            case kAXTextAreaRole:
                if text(element, kAXDescriptionAttribute) == "Message" { state.editors.append(element) }
            case kAXStaticTextRole:
                if text(element, kAXValueAttribute)?.hasPrefix("You said:") == true { state.hasUserMessages = true }
            default: break
            }
            for child in children(element, kAXChildrenAttribute) { try walk(child, depth: depth + 1) }
        }
        for window in children(root, kAXWindowsAttribute) { try walk(window, depth: 0) }
        return state
    }

    private func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return [] }
        return result as? [AXUIElement] ?? []
    }

    private func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? String
    }

    private func value(_ element: AXUIElement) -> String? {
        text(element, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enabled(_ element: AXUIElement) -> Bool {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &result) == .success
            && result as? Bool == true
    }

    private func focused(_ element: AXUIElement) -> Bool {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &result) == .success
            && result.map { CFEqual($0, element) } == true
    }

    private func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw ReviewLaunchError.scoutControlUnavailable
        }
    }
}
