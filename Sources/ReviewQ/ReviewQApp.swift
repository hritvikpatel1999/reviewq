import AppKit
import ApplicationServices
import Combine
import OSLog
import ReviewQCore
import SwiftUI
import UserNotifications

@main
enum ReviewQApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.mainMenu = makeMainMenu()
        let logger = DiagnosticLogger(
            directory: DiagnosticLogger.defaultDirectory,
            verboseEnabled: UserDefaults.standard.bool(forKey: DiagnosticLogger.verboseKey)
        )
        let diagnostics = DiagnosticsStore(logger: logger)
        let delegate = AppDelegate(store: ReviewStore(diagnostics: logger), diagnostics: diagnostics)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor
    static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let applicationMenu = NSMenu(title: "ReviewQ")
        applicationMenu.addItem(
            withTitle: "Quit ReviewQ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        let applicationItem = menu.addItem(withTitle: "ReviewQ", action: nil, keyEquivalent: "")
        applicationItem.submenu = applicationMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        return menu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate,
                         UNUserNotificationCenterDelegate, ObservableObject {
    let store: ReviewStore
    let loginItem: LoginItemStore
    let diagnostics: DiagnosticsStore
    let menuShortcut: GlobalShortcutStore
    let onboarding: OnboardingStore
    let updates: UpdateStore
    let reminders: ReminderStore
    @Published var actionError: String?
    @Published private(set) var isLaunchingReview = false
    private let reviewLauncher: any ReviewLaunching
    private let openURL: @MainActor (URL) -> Bool
    private let terminateApplication: @MainActor () -> Void
    private let presentReviewError: @MainActor (ReviewLaunchError) -> Void
    private let popover: NSPopover
    private let menuBarChangeDot = MenuBarChangeDot(frame: .zero)
    private(set) var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var localPopoverMonitor: Any?
    private var globalPopoverMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingReminderActivation = false
    private let logger = Logger(subsystem: "dev.prbar.app", category: "application")

    init(
        store: ReviewStore = ReviewStore(), diagnostics: DiagnosticsStore = DiagnosticsStore(),
        reviewLauncher: any ReviewLaunching = ReviewLauncher(),
        shortcutRegistrar: (any GlobalShortcutRegistering)? = nil, onboarding: OnboardingStore? = nil,
        updates: UpdateStore? = nil, reminders: ReminderStore? = nil,
        popover: NSPopover = NSPopover(),
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        terminateApplication: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) },
        presentReviewError: (@MainActor (ReviewLaunchError) -> Void)? = nil
    ) {
        self.store = store
        self.diagnostics = diagnostics
        self.reviewLauncher = reviewLauncher
        self.openURL = openURL
        self.terminateApplication = terminateApplication
        self.popover = popover
        let reminders = reminders ?? onboarding?.reminders ?? ReminderStore(
            notifications: LocalReminderNotifications(), diagnostics: diagnostics.logger
        )
        self.reminders = reminders
        self.onboarding = onboarding ?? OnboardingStore(
            store: store, diagnostics: diagnostics.logger, reminders: reminders
        )
        self.updates = updates ?? UpdateStore(diagnostics: diagnostics.logger)
        self.presentReviewError = presentReviewError ?? { error in
            Self.showReviewError(error, diagnostics: diagnostics.logger, openURL: openURL)
        }
        menuShortcut = GlobalShortcutStore(
            registrar: shortcutRegistrar ?? CarbonShortcutRegistrar(diagnostics: diagnostics.logger),
            diagnostics: diagnostics.logger
        )
        loginItem = LoginItemStore(diagnostics: diagnostics.logger)
        super.init()
        LocalReminderNotifications.center?.delegate = self
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
        menuBarChangeDot.frame = button.bounds
        menuBarChangeDot.autoresizingMask = [.width, .height]
        menuBarChangeDot.isHidden = true
        menuBarChangeDot.setAccessibilityElement(false)
        button.addSubview(menuBarChangeDot)
        button.target = self
        button.action = #selector(togglePopover)
        for name in [NSWindow.didExposeNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.publisher(for: name, object: button.window)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.openReminderQueue() }
                .store(in: &subscriptions)
        }
        // Transient dismissal can close on mouse-down before the button's toggle on mouse-up.
        popover.behavior = .applicationDefined
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
                self?.updates.requestCheck()
                self?.reminders.requestSynchronization()
            }
            .store(in: &subscriptions)
        for name in [NSApplication.didBecomeActiveNotification, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    self?.reminders.requestSynchronization(force: notification.name != NSApplication.didBecomeActiveNotification)
                }
                .store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.diagnostics.logger.log(.info, .sleep) }
            .store(in: &subscriptions)
        // Menu-bar interaction can resign activity before the status button sends its action.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleApplicationActivation(notification)
            }
            .store(in: &subscriptions)
        updateStatusItem()
        startMenuShortcut()
        store.start()
        updates.requestCheck()
        reminders.requestSynchronization()
        if pendingReminderActivation {
            DispatchQueue.main.async { [weak self] in self?.openReminderQueue() }
        } else if CommandLine.arguments.contains("--diagnostics") {
            showDiagnostics()
        } else if CommandLine.arguments.contains("--setup") || onboarding.shouldPresentAutomatically {
            showOnboarding()
        } else if !store.configuration.hasSources || store.errorMessage != nil || menuShortcut.errorMessage != nil {
            showSettings()
        } else if let error = onboarding.errorMessage {
            actionError = error
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        diagnostics.logger.log(.info, .appReopened)
        if pendingReminderActivation { return false }
        if onboarding.shouldPresentAutomatically {
            showOnboarding()
        } else {
            showSettings()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingReminderActivation = false
        closePopover()
        onboarding.pause()
        updates.cancel()
        menuShortcut.stop()
        store.stop()
        diagnostics.recordShutdown()
        subscriptions.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func handleApplicationActivation(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            diagnostics.logger.log(.warning, .applicationActionFailed, operation: .application, reason: .invalidResponse)
            logger.error("An application activation notification did not include its application.")
            return
        }
        handleApplicationActivation(processIdentifier: application.processIdentifier, isActive: application.isActive)
    }

    func handleApplicationActivation(processIdentifier: Int32, isActive: Bool) {
        guard isActive, processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        closePopover()
    }

    func startMenuShortcut() {
        menuShortcut.start { [weak self] in self?.togglePopover() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        await handleReminderResponse(identifier: identifier, actionIdentifier: action)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier.hasPrefix(ReminderNotification.identifierPrefix) else { return [] }
        return [.banner, .list, .sound]
    }

    func handleReminderResponse(identifier: String, actionIdentifier: String) {
        guard identifier.hasPrefix(ReminderNotification.identifierPrefix),
              actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        diagnostics.logger.log(.info, .reminderOpened, operation: .reminders)
        pendingReminderActivation = true
        if statusItem != nil { openReminderQueue() }
    }

    private func openReminderQueue() {
        guard pendingReminderActivation, let window = statusItem?.button?.window,
              window.isVisible, !window.frame.isEmpty else { return }
        pendingReminderActivation = false
        showQueue()
        store.requestRefresh()
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
              openURL(url) else {
            reportActionFailure(
                "Could not open notification settings. Open System Settings > Notifications and choose ReviewQ.",
                operation: .reminders
            )
            return
        }
        actionError = nil
        closePopover()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showQueue()
        }
    }

    func showQueue() {
        guard let button = statusItem?.button else {
            reportActionFailure("ReviewQ's menu-bar button is unavailable. Restart the app.")
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        startPopoverDismissalMonitoring()
        updates.requestCheck()
    }

    func closePopover() {
        stopPopoverDismissalMonitoring()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverDismissalMonitoring()
        statusItem?.button?.highlight(false)
    }

    private func startPopoverDismissalMonitoring() {
        guard popover.isShown, localPopoverMonitor == nil, globalPopoverMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localPopoverMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self.popover.contentViewController?.view.window else { return }
                guard !self.isStatusButtonEvent(event) else { return }
                self.closePopover()
            }
            return event
        }
        globalPopoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobalPopoverMouseDown(event) }
        }
        if localPopoverMonitor == nil || globalPopoverMonitor == nil {
            reportActionFailure(
                "Click-away dismissal is unavailable. Close the queue with its menu-bar icon or Command-Option-Q."
            )
        }
    }

    func handleGlobalPopoverMouseDown(_ event: NSEvent) {
        guard !isStatusButtonEvent(event) else { return }
        closePopover()
    }

    private func isStatusButtonEvent(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.contains(location)
    }

    private func stopPopoverDismissalMonitoring() {
        if let localPopoverMonitor { NSEvent.removeMonitor(localPopoverMonitor) }
        if let globalPopoverMonitor { NSEvent.removeMonitor(globalPopoverMonitor) }
        localPopoverMonitor = nil
        globalPopoverMonitor = nil
    }

    func showSettings() {
        if onboardingWindow != nil || onboarding.isActive {
            showOnboarding()
            return
        }
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

    @discardableResult
    func showOnboarding() -> String? {
        guard settingsWindow == nil else {
            let message = "Close Settings before running setup. Your unsaved Settings edits have not been changed."
            reportActionFailure(message, reason: .invalidConfiguration)
            return message
        }
        closePopover()
        if onboardingWindow == nil {
            onboarding.begin()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "ReviewQ Setup"
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 720, height: 640)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: OnboardingView(model: onboarding, app: self))
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        actionError = nil
        NSApplication.shared.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        return nil
    }

    func finishOnboarding() {
        onboardingWindow?.close()
        showQueue()
    }

    func requestScoutAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                  NSWorkspace.shared.open(url) else {
                let message = "Open System Settings > Privacy & Security > Accessibility and allow ReviewQ."
                reportActionFailure(message, operation: .scout, reason: .approvalPending)
                onboarding.reportActionError(message)
                return
            }
        }
        onboarding.refreshCompanions()
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
        } else if let window = notification.object as? NSWindow, window === onboardingWindow {
            onboarding.pause()
            onboardingWindow = nil
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === diagnosticsWindow {
            diagnostics.logger.log(.info, .diagnosticsOpened, operation: .application)
            logger.notice("Diagnostics window became key.")
        }
    }

    func quit() { terminateApplication() }

    func open(_ url: URL) {
        if openURL(url) {
            actionError = nil
            closePopover()
        } else {
            reportActionFailure(
                "macOS could not open this link. Check your default browser.",
                event: .browserOpenFailed, operation: .browser
            )
        }
    }

    func review(_ request: ReviewPullRequest, with assistant: ReviewAssistant) async {
        guard !isLaunchingReview else {
            reportActionFailure(
                "Wait for the current review chat to open before starting another.",
                event: .reviewLaunchFailed, operation: assistant.diagnosticOperation
            )
            return
        }
        isLaunchingReview = true
        actionError = nil
        let requestID = UUID()
        let start = ContinuousClock.now
        diagnostics.logger.log(.info, .reviewLaunchStarted, operation: assistant.diagnosticOperation, requestID: requestID)
        defer { isLaunchingReview = false }
        do {
            try await reviewLauncher.launch(
                assistant, for: request.url,
                additionalInstructions: assistant.additionalInstructions(in: store.configuration)
            )
            diagnostics.logger.log(
                .info, .reviewLaunchFinished, operation: assistant.diagnosticOperation, requestID: requestID,
                durationMilliseconds: DiagnosticTiming.milliseconds(since: start)
            )
            closePopover()
        } catch is CancellationError {
            diagnostics.logger.log(
                .info, .reviewLaunchFailed, operation: assistant.diagnosticOperation,
                requestID: requestID, reason: .cancelled,
                durationMilliseconds: DiagnosticTiming.milliseconds(since: start)
            )
        } catch {
            let failure: ReviewLaunchError
            if let error = error as? ReviewLaunchError {
                failure = error
            } else if let error = error as? LocalCommandError {
                switch error {
                case .unavailable: failure = .appUnavailable(assistant)
                case .timeout: failure = .commandTimedOut
                case .failed(let code): failure = .commandFailed(code)
                }
            } else {
                failure = .launchFailed
            }
            actionError = failure.localizedDescription
            diagnostics.logger.log(
                .warning, .reviewLaunchFailed, operation: assistant.diagnosticOperation,
                requestID: requestID, reason: failure.diagnosticReason,
                durationMilliseconds: DiagnosticTiming.milliseconds(since: start),
                systemCode: failure.diagnosticSystemCode ?? DiagnosticFailure(error).systemCode
            )
            logger.error("Review launch failed. Check ReviewQ Diagnostics.")
            closePopover()
            presentReviewError(failure)
        }
    }

    func openInEdge(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac") else {
            reportActionFailure(
                "Microsoft Edge is not installed. Install Edge, or click the PR row to use your default browser.",
                event: .browserOpenFailed, operation: .browser, reason: .cliUnavailable
            )
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] application, error in
            let succeeded = application != nil && error == nil
            let failure = error.map(DiagnosticFailure.init)
            Task { @MainActor [weak self] in
                self?.handleEdgeOpen(succeeded: succeeded, failure: failure)
            }
        }
    }

    func handleEdgeOpen(succeeded: Bool, failure: DiagnosticFailure?) {
        if succeeded {
            actionError = nil
            closePopover()
        } else {
            reportActionFailure(
                "macOS could not open this PR in Edge. Check that Edge opens normally.",
                event: .browserOpenFailed, operation: .browser,
                reason: failure?.reason ?? .system, systemCode: failure?.systemCode
            )
        }
    }

    private static func showReviewError(
        _ error: ReviewLaunchError, diagnostics: DiagnosticLogger, openURL: (URL) -> Bool
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Could not start review"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if error == .accessibilityRequired { alert.addButton(withTitle: "Open Accessibility Settings") }
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn, error == .accessibilityRequired {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                  openURL(url) else {
                diagnostics.log(.warning, .applicationActionFailed, operation: .scout, reason: .system)
                let failure = NSAlert()
                failure.messageText = "Open System Settings manually"
                failure.informativeText = "Choose Privacy & Security > Accessibility and allow ReviewQ."
                failure.runModal()
                return
            }
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
        operation: DiagnosticOperation = .application, reason: DiagnosticReason = .system, systemCode: Int? = nil
    ) {
        actionError = message
        diagnostics.logger.log(
            reason == .cancelled ? .info : .warning, event, operation: operation, reason: reason, systemCode: systemCode
        )
        if reason != .cancelled { logger.error("App action failed. Check ReviewQ Diagnostics.") }
    }

    private func updateStatusItem() {
        statusItem?.button?.title = store.menuBarTitle
        menuBarChangeDot.isHidden = !store.changes.hasChanges
        menuBarChangeDot.needsDisplay = true
        var description: String
        if let error = store.errorMessage {
            description = "ReviewQ - refresh error: \(error)"
        } else if store.snapshot != nil {
            description = "ReviewQ - \(store.pendingReviewCount) pull requests need your review"
        } else {
            description = store.configuration.hasSources ? "ReviewQ - loading reviews" : "ReviewQ - connect Azure DevOps"
        }
        if store.changes.hasChanges {
            description += ". Changes since the previous successful refresh"
        }
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel(description)
    }
}

final class MenuBarChangeDot: NSView {
    override var isFlipped: Bool { superview?.isFlipped ?? false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let button = superview as? NSButton, let cell = button.cell else {
            preconditionFailure("The menu-bar change indicator must overlay a button.")
        }
        let image = cell.imageRect(forBounds: button.bounds)
        let y = isFlipped ? image.minY - 1 : image.maxY - 4
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: image.maxX - 3, y: y, width: 5, height: 5)).fill()
    }
}
