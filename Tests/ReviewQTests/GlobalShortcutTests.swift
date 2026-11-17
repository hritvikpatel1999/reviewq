import AppKit
import Carbon
@testable import ReviewQ
@testable import ReviewQCore
import XCTest

@MainActor
final class GlobalShortcutTests: XCTestCase {
    func testShortcutIsCommandOptionQOnReleaseWithoutExtraModifiers() {
        XCTAssertEqual(CarbonShortcutRegistrar.keyCode, UInt32(kVK_ANSI_Q))
        XCTAssertEqual(CarbonShortcutRegistrar.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(CarbonShortcutRegistrar.modifiers & UInt32(shiftKey | controlKey), 0)
        XCTAssertEqual(CarbonShortcutRegistrar.eventKind, UInt32(kEventHotKeyReleased))
        XCTAssertNotEqual(CarbonShortcutRegistrar.signature, 0x4C42_724B)
    }

    func testStartAndStopAreIdempotentAndDeliverOnlyTheRegisteredAction() {
        let registrar = ShortcutRegistrarFake()
        let store = GlobalShortcutStore(registrar: registrar)
        var calls = 0
        store.start { calls += 1 }
        store.start { calls += 100 }
        XCTAssertEqual(registrar.registrations, 1)
        registrar.action?()
        XCTAssertEqual(calls, 1)
        store.stop()
        store.stop()
        XCTAssertEqual(registrar.unregistrations, 1)
        XCTAssertNil(registrar.action)
        store.start { calls += 1 }
        registrar.action?()
        XCTAssertEqual(calls, 2)
        store.stop()
    }

    func testConflictIsVisibleAndCanBeRetriedWithoutRestarting() throws {
        let registrar = ShortcutRegistrarFake()
        registrar.failure = GlobalShortcutError(status: OSStatus(eventHotKeyExistsErr))
        let store = GlobalShortcutStore(registrar: registrar)
        store.start { XCTFail("A failed registration must not deliver a shortcut.") }
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("already in use"))
        XCTAssertNil(registrar.action)
        store.stop()
        XCTAssertEqual(registrar.unregistrations, 0)
        registrar.failure = nil
        store.start {}
        XCTAssertEqual(registrar.registrations, 2)
        XCTAssertNil(store.errorMessage)
        store.stop()
    }

    func testSystemAndCleanupFailuresRemainVisible() {
        let registrar = ShortcutRegistrarFake()
        let store = GlobalShortcutStore(registrar: registrar)
        registrar.failure = GlobalShortcutError(status: -50)
        store.start {}
        XCTAssertTrue(store.errorMessage?.contains("-50") == true)
        registrar.failure = nil
        store.start {}
        registrar.cleanupFailure = GlobalShortcutError(status: -50, isUnregistering: true)
        store.stop()
        XCTAssertTrue(store.errorMessage?.contains("could not be released") == true)
    }

    func testForeignAndUnregisteredIdentifiersArePassedAlong() {
        let registrar = CarbonShortcutRegistrar()
        for identifier in [
            EventHotKeyID(signature: CarbonShortcutRegistrar.signature, id: 1),
            EventHotKeyID(signature: 0, id: 1),
            EventHotKeyID(signature: CarbonShortcutRegistrar.signature, id: 2)
        ] {
            XCTAssertEqual(registrar.handle(identifier: identifier), OSStatus(eventNotHandledErr))
        }
    }

    func testStatusClicksAndShortcutReleasesAlwaysToggleTheSamePopover() async throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        defer { application.setActivationPolicy(previousPolicy) }
        try await Task.sleep(for: .milliseconds(100))
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var configuration = ReviewConfiguration()
        configuration.sourceURLs = "https://dev.azure.com/example/Project"
        try fixture.store.save(configuration)
        let registrar = ShortcutRegistrarFake()
        let popover = NSPopover()
        let app = AppDelegate(
            store: fixture.store, diagnostics: DiagnosticsStore(logger: .disabled, defaults: fixture.defaults),
            shortcutRegistrar: registrar, onboarding: fixture.model, updates: fixture.updates, popover: popover
        )
        defer {
            app.closePopover()
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            popover.contentViewController = nil
        }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await showStatusItem(app)
        let button = try XCTUnwrap(app.statusItem?.button)
        let applicationDelegate: any NSApplicationDelegate = app
        try clickStatusButton(button)
        XCTAssertTrue(popover.isShown)
        for _ in 0..<3 {
            let buttonWindow = try XCTUnwrap(button.window)
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let hostedPress = try mouseEvent(
                .leftMouseDown, in: nil, at: NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            )
            XCTAssertNil(hostedPress.window)
            app.handleGlobalPopoverMouseDown(hostedPress)
            XCTAssertTrue(popover.isShown, "A menu-bar-hosted mouse-down must not dismiss before the icon action.")
            applicationDelegate.applicationDidResignActive?(Notification(name: NSApplication.didResignActiveNotification))
            XCTAssertTrue(popover.isShown, "Temporary menu-bar deactivation must not dismiss before the icon action.")
            try clickStatusButton(button)
            XCTAssertFalse(popover.isShown, "Clicking an open queue must close it, not dismiss and reopen it.")
            try clickStatusButton(button)
            XCTAssertTrue(popover.isShown)
            try sendShortcutKeyDown(to: popover)
            XCTAssertTrue(popover.isShown, "The shortcut must toggle once on release, not dismiss on key-down.")
            registrar.action?()
            XCTAssertFalse(popover.isShown, "The same shortcut must close a queue opened by the status icon.")
            registrar.action?()
            XCTAssertTrue(popover.isShown)
            await Task.yield()
        }
        let startupChecks = await fixture.updateClient.calls
        XCTAssertEqual(startupChecks, 1, "Launch and repeated queue openings share the same daily check.")
        await fixture.store.refresh()
        let checksAfterPRRefresh = await fixture.updateClient.calls
        XCTAssertEqual(checksAfterPRRefresh, startupChecks, "PR refreshes must not check application releases.")
        fixture.updateClock.now.addTimeInterval(24 * 3_600)
        let queueCheck = expectation(description: "Opening the queue checks when the daily interval has elapsed")
        await fixture.updateClient.onNextCheck { queueCheck.fulfill() }
        registrar.action?()
        registrar.action?()
        await fulfillment(of: [queueCheck], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(fixture.updates.isChecking)
        fixture.updateClock.now.addTimeInterval(24 * 3_600)
        let wakeCheck = expectation(description: "Waking checks app updates when due")
        await fixture.updateClient.onNextCheck { wakeCheck.fulfill() }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        await fulfillment(of: [wakeCheck], timeout: 2)
        let checksAfterWake = await fixture.updateClient.calls
        XCTAssertEqual(checksAfterWake, 3)
    }

    func testClickAwayEscapeAndAppSwitchCloseTheQueueAndAllowReopening() async throws {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        defer { application.setActivationPolicy(previousPolicy) }
        try await Task.sleep(for: .milliseconds(100))
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var configuration = ReviewConfiguration()
        configuration.sourceURLs = "https://dev.azure.com/example/Project"
        try fixture.store.save(configuration)
        let registrar = ShortcutRegistrarFake()
        let popover = NSPopover()
        let app = AppDelegate(
            store: fixture.store, diagnostics: DiagnosticsStore(logger: .disabled, defaults: fixture.defaults),
            shortcutRegistrar: registrar, onboarding: fixture.model, updates: fixture.updates, popover: popover
        )
        let outside = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let clickTarget = PopoverClickTarget(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        outside.isReleasedWhenClosed = false
        outside.contentView = clickTarget
        outside.orderFront(nil)
        defer {
            app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            popover.contentViewController = nil
            outside.close()
        }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try await showStatusItem(app)
        registrar.action?()
        XCTAssertTrue(popover.isShown)
        let content = try XCTUnwrap(popover.contentViewController?.view)
        let window = try XCTUnwrap(content.window)
        let inside = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            application.sendEvent(try mouseEvent(type, in: window, at: inside))
        }
        XCTAssertTrue(popover.isShown, "Interacting inside the queue must not dismiss it.")

        application.sendEvent(try mouseEvent(.leftMouseDown, in: outside, at: NSPoint(x: 50, y: 50)))
        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(clickTarget.clicks, 1, "Click-away dismissal must not swallow the outside click.")
        registrar.action?()
        XCTAssertTrue(popover.isShown)

        let reopenedWindow = try XCTUnwrap(popover.contentViewController?.view.window)
        application.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reopenedWindow.windowNumber,
            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)
        )))
        XCTAssertFalse(popover.isShown, "Escape must still dismiss an application-defined popover.")
        registrar.action?()
        XCTAssertTrue(popover.isShown)
        app.handleGlobalPopoverMouseDown(try mouseEvent(
            .leftMouseDown, in: nil, at: NSPoint(x: outside.frame.midX, y: outside.frame.midY)
        ))
        XCTAssertFalse(popover.isShown, "A windowless global click away from the icon must still dismiss.")
        registrar.action?()
        XCTAssertTrue(popover.isShown)
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        app.handleApplicationActivation(processIdentifier: ownProcessIdentifier, isActive: true)
        XCTAssertTrue(popover.isShown, "Our own activation must not close a queue opened from another app.")
        app.handleApplicationActivation(processIdentifier: ownProcessIdentifier + 1, isActive: false)
        XCTAssertTrue(popover.isShown, "A queued activation for an app that is no longer active must not close the queue.")
        app.handleApplicationActivation(processIdentifier: ownProcessIdentifier + 1, isActive: true)
        XCTAssertFalse(popover.isShown)
        registrar.action?()
        XCTAssertTrue(popover.isShown, "Automatic dismissal must not leave the toggle in a stale state.")
    }

    private func showStatusItem(_ app: AppDelegate) async throws {
        let window = try XCTUnwrap(app.statusItem?.button?.window)
        // XCTest has no NSApplication.run loop to order the status item's positioning window.
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(2)
        while window.frame.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            drainEvents()
        }
        drainEvents()
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.frame.isEmpty, "The status item's positioning window must be laid out: \(window.frame)")
    }

    private func drainEvents() {
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {
            while let event = NSApplication.shared.nextEvent(
                matching: .any, until: .distantPast, inMode: .default, dequeue: true
            ) {
                NSApplication.shared.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
    }

    private func clickStatusButton(_ button: NSButton) throws {
        let window = try XCTUnwrap(button.window)
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApplication.shared.postEvent(try mouseEvent(type, in: window, at: location), atStart: false)
        }
        drainEvents()
    }

    private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow?, at location: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    private func sendShortcutKeyDown(to popover: NSPopover) throws {
        let window = try XCTUnwrap(popover.contentViewController?.view.window)
        NSApplication.shared.postEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_Q)
        )), atStart: false)
        drainEvents()
    }
}

@MainActor
private final class PopoverClickTarget: NSView {
    var clicks = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}

@MainActor
private final class ShortcutRegistrarFake: GlobalShortcutRegistering {
    var registrations = 0
    var unregistrations = 0
    var failure: GlobalShortcutError?
    var cleanupFailure: GlobalShortcutError?
    var action: (@MainActor () -> Void)?

    func register(action: @escaping @MainActor () -> Void) throws {
        registrations += 1
        if let failure { throw failure }
        self.action = action
    }

    func unregister() throws {
        unregistrations += 1
        action = nil
        if let cleanupFailure { throw cleanupFailure }
    }
}
