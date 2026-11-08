import AppKit
import Combine
import OSLog
import ReviewQCore
import SwiftUI

@main
enum ReviewQApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let logger = DiagnosticLogger(
            directory: DiagnosticLogger.defaultDirectory,
            verboseEnabled: UserDefaults.standard.bool(forKey: DiagnosticLogger.verboseKey)
        )
        let diagnostics = DiagnosticsStore(logger: logger)
        let delegate = AppDelegate(store: ReviewStore(diagnostics: logger), diagnostics: diagnostics)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, ObservableObject {
    let store: ReviewStore
    let loginItem: LoginItemStore
    let diagnostics: DiagnosticsStore
    @Published var actionError: String?
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "dev.prbar.app", category: "application")

    init(store: ReviewStore = ReviewStore(), diagnostics: DiagnosticsStore = DiagnosticsStore()) {
        self.store = store
        self.diagnostics = diagnostics
        loginItem = LoginItemStore(diagnostics: diagnostics.logger)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostics.recordStartup()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button,
              let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull requests")
        else { preconditionFailure("The native ReviewQ status icon is unavailable.") }
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(
            rootView: DashboardView(store: store, app: self)
                .onExitCommand { [weak self] in self?.closePopover() }
        )
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 440, height: 540)
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.diagnostics.logger.log(.info, .wake)
                self?.store.requestRefresh()
            }
            .store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.diagnostics.logger.log(.info, .sleep) }
            .store(in: &subscriptions)
        updateStatusItem()
        store.start()
        if CommandLine.arguments.contains("--diagnostics") {
            showDiagnostics()
        } else if !store.configuration.hasSources || store.errorMessage != nil {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        diagnostics.logger.log(.info, .appReopened)
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        diagnostics.recordShutdown()
        subscriptions.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            guard let button = statusItem?.button else {
                reportActionFailure("ReviewQ's menu-bar button is unavailable. Restart the app.")
                return
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            button.highlight(true)
        }
    }

    func closePopover() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
    }

    func showSettings() {
        closePopover()
        loginItem.refresh()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "ReviewQ Settings"
            window.contentMinSize = NSSize(width: 520, height: 540)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(store: store, app: self, loginItem: loginItem)
            )
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showDiagnostics() {
        closePopover()
        if diagnosticsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "ReviewQ Diagnostics"
            window.contentMinSize = NSSize(width: 520, height: 420)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DiagnosticsView(diagnostics: diagnostics))
            window.delegate = self
            window.center()
            diagnosticsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
        } else if let window = notification.object as? NSWindow, window === diagnosticsWindow {
            diagnosticsWindow = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === diagnosticsWindow {
            diagnostics.logger.log(.info, .diagnosticsOpened, operation: .application)
            logger.notice("Diagnostics window became key.")
        }
    }

    func open(_ url: URL) {
        if NSWorkspace.shared.open(url) {
            actionError = nil
            closePopover()
        } else {
            reportActionFailure(
                "macOS could not open this link. Check your default browser.",
                event: .browserOpenFailed, operation: .browser
            )
        }
    }

    func openDocumentation(_ text: String) {
        guard let url = URL(string: text), url.scheme == "https" else {
            reportActionFailure(
                "The documentation link is invalid.", event: .browserOpenFailed,
                operation: .browser, reason: .invalidConfiguration
            )
            return
        }
        open(url)
    }

    private func reportActionFailure(
        _ message: String, event: DiagnosticEvent = .applicationActionFailed,
        operation: DiagnosticOperation = .application, reason: DiagnosticReason = .system
    ) {
        actionError = message
        diagnostics.logger.log(.warning, event, operation: operation, reason: reason)
        logger.error("App action failed. Check ReviewQ Diagnostics.")
    }

    private func updateStatusItem() {
        statusItem?.button?.title = store.menuBarTitle
        let description: String
        if let error = store.errorMessage {
            description = "ReviewQ - refresh error: \(error)"
        } else if let snapshot = store.snapshot {
            description = "ReviewQ - \(snapshot.pullRequests.count) pull requests need your review"
        } else {
            description = store.configuration.hasSources ? "ReviewQ - loading reviews" : "ReviewQ - connect Azure DevOps"
        }
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel(description)
    }
}
