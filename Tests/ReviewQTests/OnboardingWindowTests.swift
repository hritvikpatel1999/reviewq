import AppKit
@testable import ReviewQ
@testable import ReviewQCore
import SwiftUI
import Vision
import XCTest

@MainActor
final class OnboardingWindowTests: XCTestCase {
    func testReminderControlsEditDaysAndTimesPreviewAndSaveWithoutApplyingDraftsInBothAppearances() async throws {
        for dark in [false, true] {
            let fixture = try OnboardingFixture()
            defer { fixture.close() }
            let host = NSHostingView(rootView: ReminderSettingsHarness(model: fixture.model, openSettings: {})
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            let window = makeWindow(host)
            defer { window.close() }
            window.setContentSize(NSSize(width: 560, height: 700))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(host)
            try exportPreview(capture(host), name: "reminders-initial-\(dark ? "dark" : "light")")
            XCTAssertFalse(fixture.model.reminderDraft.isEnabled)
            XCTAssertEqual(fixture.reminderCenter.permissionRequests, 0)
            try press("Enable review reminders", in: host)
            try await settle(host)
            await fixture.reminders.waitUntilIdle()
            XCTAssertTrue(fixture.model.reminderDraft.isEnabled)
            XCTAssertFalse(fixture.model.reminderDraft.playsSound)
            XCTAssertEqual(fixture.reminderCenter.permissionRequests, 1)
            XCTAssertTrue(fixture.reminderCenter.pending.isEmpty)
            XCTAssertNil(fixture.defaults.object(forKey: ReminderStore.settingsKey))
            let originalTimes = fixture.model.reminderDraft.times
            try press("Add time", in: host, matchingSubstring: true)
            try await settle(host)
            XCTAssertEqual(fixture.model.reminderDraft.times.count, 3)
            try exportPreview(capture(host), name: "reminders-three-times-\(dark ? "dark" : "light")")
            let lastTime = rect(try text("Time 3", in: capture(host), matchingSubstring: true, topCandidateOnly: true), in: host)
            try press(at: NSPoint(x: lastTime.minX + 255, y: lastTime.midY), in: host)
            try await settle(host)
            XCTAssertEqual(fixture.model.reminderDraft.times.count, 2, "Removing a time must keep the remaining DatePicker bindings valid.")
            XCTAssertEqual(fixture.model.reminderDraft.times, originalTimes, "Removing the third row at \(lastTime) must preserve the first two times.")
            try press("Sat", in: host)
            try await settle(host)
            XCTAssertTrue(fixture.model.reminderDraft.weekdays.contains(7))
            try press("Send test", in: host, matchingSubstring: true)
            try await settle(host)
            await fixture.reminders.waitUntilIdle()
            XCTAssertEqual(fixture.reminderCenter.pending.count, 1)
            XCTAssertEqual(fixture.reminderCenter.pending.values.first?.trigger, .test)
            XCTAssertFalse(fixture.reminders.configuration.isEnabled, "An explicit test must not save or enable the draft.")
            try exportPreview(capture(host), name: "reminders-\(dark ? "dark" : "light")")
            try press("Save reminders", in: host)
            try await settle(host)
            await fixture.reminders.waitUntilIdle()
            XCTAssertEqual(fixture.reminders.configuration, fixture.model.reminderDraft)
            XCTAssertEqual(fixture.reminderCenter.pending.values.filter {
                if case .weekly = $0.trigger { return true }
                return false
            }.count, 12)
            try press("Enable review reminders", in: host)
            try await settle(host)
            XCTAssertTrue(fixture.reminders.configuration.isEnabled, "Opt-out is also a draft until saved.")
            try press("Save reminders", in: host)
            try await settle(host)
            await fixture.reminders.waitUntilIdle()
            XCTAssertTrue(fixture.reminderCenter.pending.isEmpty)
            XCTAssertFalse(fixture.reminders.configuration.isEnabled)
        }
    }

    func testBlockedReminderPermissionKeepsSetupOptionalAndLinksToSystemSettings() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        fixture.reminderCenter.permissionResult = .denied
        var settingsOpened = 0
        let host = NSHostingView(rootView: ReminderSettingsHarness(
            model: fixture.model, openSettings: { settingsOpened += 1 }
        ).environment(\.locale, Locale(identifier: "en_US")))
        let window = makeWindow(host)
        defer { window.close() }
        window.setContentSize(NSSize(width: 560, height: 700))
        try await settle(host)
        try press("Enable review reminders", in: host)
        try await settle(host)
        await fixture.reminders.waitUntilIdle()
        _ = try text("You can still finish setup", in: capture(host), matchingSubstring: true)
        try press("Open Notif", in: host, matchingSubstring: true)
        XCTAssertEqual(settingsOpened, 1)
        try press("Save reminders", in: host)
        try await settle(host)
        await fixture.reminders.waitUntilIdle()
        XCTAssertTrue(fixture.reminders.configuration.isEnabled)
        XCTAssertFalse(fixture.reminders.isScheduled)
        XCTAssertTrue(fixture.reminderCenter.pending.isEmpty)
        XCTAssertEqual(fixture.reminderCenter.permissionRequests, 1)
    }

    func testSixPagesKeepNavigationVisibleAtMinimumAndDefaultSizesInBothAppearances() async throws {
        for dark in [false, true] {
            let fixture = try OnboardingFixture()
            defer { fixture.close() }
            let app = AppDelegate(store: fixture.store, onboarding: fixture.model, updates: fixture.updates)
            let host = NSHostingView(rootView: OnboardingView(model: fixture.model, app: app)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            let window = makeWindow(host)
            defer { window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for step in OnboardingStep.allCases {
                await fixture.reach(step)
                if step == .authentication { await fixture.model.testConnection() }
                for size in [NSSize(width: 720, height: 640), NSSize(width: 800, height: 700)] {
                    window.setContentSize(size)
                    try await settle(host)
                    let image = try capture(host)
                    let primary = try text(fixture.model.primaryButtonTitle, in: image)
                    let content = host.convert(host.bounds, to: nil).insetBy(dx: -1, dy: -1)
                    let button = host.convert(rect(primary, in: host), to: nil)
                    XCTAssertTrue(content.contains(button), "Navigation clipped on \(step) at \(size).")
                    XCTAssertLessThan(button.maxY, 100, "Continue belongs in the fixed footer, not the scrollable card.")
                    XCTAssertLessThanOrEqual(host.intrinsicContentSize.width, size.width + 1)
                    if size.width == 800 { try exportPreview(image, name: "\(step.rawValue)-\(dark ? "dark" : "light")") }
                }
            }
        }
    }

    func testNativeContinueBackAndSkipControlsNavigateWithoutRequestingPermissions() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        fixture.model.begin()
        let app = AppDelegate(store: fixture.store, onboarding: fixture.model, updates: fixture.updates)
        let host = NSHostingView(rootView: OnboardingView(model: fixture.model, app: app))
        let window = makeWindow(host)
        defer { window.close() }
        try await settle(host)
        try press("Get started", in: host)
        try await settle(host)
        XCTAssertEqual(fixture.model.step, .sources)
        fixture.model.draft.sourceURLs = "https://dev.azure.com/example/Project"
        try await settle(host)
        try press("Continue", in: host)
        try await settle(host)
        XCTAssertEqual(fixture.model.step, .authentication)
        try press("Continue", in: host)
        try await settle(host)
        XCTAssertEqual(fixture.model.step, .authentication, "Continue must stay disabled until a successful connection test.")
        try press("Test connection", in: host)
        try await settle(host)
        XCTAssertTrue(fixture.model.hasVerifiedConnection)
        try press("Continue", in: host)
        try await settle(host)
        XCTAssertEqual(fixture.model.step, .companions)
        try press("Skip for now", in: host)
        try await settle(host)
        XCTAssertEqual(fixture.model.step, .preferences)
        try press("Back", in: host)
        try await settle(host)
        XCTAssertEqual(fixture.model.step, .companions)
        XCTAssertFalse(fixture.model.companions.scoutAccessibilityAllowed)
        XCTAssertEqual(fixture.checks.configurations.count, 1, "Assistant detection and navigation must not fetch Azure DevOps.")
        XCTAssertEqual(fixture.reminderCenter.permissionRequests, 0, "Opening Setup alone must never request notification access.")
    }

    func testDashboardToolbarAndFooterPlacementPreserveActionsAndOpenSettings() async throws {
        for dark in [false, true] {
            let fixture = try OnboardingFixture()
            defer { fixture.close() }
            var configuration = ReviewConfiguration()
            configuration.sourceURLs = "https://dev.azure.com/example/Project"
            try fixture.store.save(configuration)
            var openedURLs: [URL] = []
            var quitRequests = 0
            let app = AppDelegate(
                store: fixture.store,
                diagnostics: DiagnosticsStore(logger: .disabled, defaults: fixture.defaults),
                onboarding: fixture.model, updates: fixture.updates,
                openURL: { openedURLs.append($0); return openedURLs.count != 2 },
                terminateApplication: { quitRequests += 1 }
            )
            let host = NSHostingView(rootView: DashboardView(store: fixture.store, app: app)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            let window = makeWindow(host)
            defer { window.close(); closeWindows() }
            window.setContentSize(NSSize(width: 440, height: 540))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(host)
            let unloadedToolbar = try toolbarTargets(in: host)
            let unloadedCredit = try text("By: Hritvik Patel", in: capture(host))
            XCTAssertGreaterThan(unloadedCredit.minX, 0.65)
            XCTAssertLessThan(unloadedCredit.maxY, 0.1, "The credit replaces setup at the bottom-right.")
            await fixture.store.refresh()
            try await settle(host)
            let image = try capture(host)
            let loadedToolbar = try toolbarTargets(in: host)
            for (unloaded, loaded) in zip(unloadedToolbar, loadedToolbar) {
                XCTAssertEqual(unloaded.x, loaded.x, accuracy: 1)
            }
            let updated = try text("Updated", in: image, matchingPrefix: true)
            let credit = try text("By: Hritvik Patel", in: image)
            XCTAssertLessThan(updated.maxX, credit.minX)
            XCTAssertEqual(updated.midY, credit.midY, accuracy: 4 / host.bounds.height)
            XCTAssertLessThan(credit.maxY, 0.1)
            try press("By: Hritvik Patel", in: host)
            XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://github.com/hritvikpatel1999"])
            XCTAssertNil(app.actionError)
            try exportPreview(image, name: "dashboard-\(dark ? "dark" : "light")")

            try press("By: Hritvik Patel", in: host)
            XCTAssertTrue(app.actionError?.contains("default browser") == true)
            try press("By: Hritvik Patel", in: host)
            XCTAssertNil(app.actionError)

            try press(at: loadedToolbar[3], in: host)
            XCTAssertEqual(quitRequests, 1, "The far-right power icon must invoke Quit.")
            let refreshes = await fixture.loader.calls
            try press(at: loadedToolbar[1], in: host)
            try await settle(host)
            let refreshed = await fixture.loader.calls
            XCTAssertEqual(refreshed, refreshes + 1)

            try press(at: loadedToolbar[2], in: host)
            let settings = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "ReviewQ Settings" && $0.isVisible })
            window.makeKeyAndOrderFront(nil)
            try press("Setup", in: host)
            try await settle(host)
            XCTAssertNotNil(app.actionError)
            XCTAssertTrue(settings.isVisible)
            XCTAssertFalse(fixture.model.isActive)
            settings.close()
            try press("Setup", in: host)
            try await settle(host)
            XCTAssertNil(app.actionError)
            XCTAssertTrue(fixture.model.isActive)
            XCTAssertTrue(NSApplication.shared.windows.contains { $0.title == "ReviewQ Setup" && $0.isVisible })
            XCTAssertTrue(fixture.checks.configurations.isEmpty, "Opening setup must not test the connection automatically.")
        }
    }

    func testUpdateBannerFitsBelowTheToolbarAndPreservesTheQueueInBothAppearances() async throws {
        for dark in [false, true] {
            let fixture = try OnboardingFixture()
            defer { fixture.close() }
            var configuration = ReviewConfiguration()
            configuration.sourceURLs = "https://dev.azure.com/example/Project"
            try fixture.store.save(configuration)
            await fixture.store.refresh()
            let snapshot = fixture.store.snapshot
            let menuTitle = fixture.store.menuBarTitle
            let release = try AvailableUpdate(
                version: "3.1.2",
                releaseURL: XCTUnwrap(URL(string: "https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.1.2"))
            )
            await fixture.updateClient.setResult(.modified(release: release, entityTag: "\"banner\""))
            await fixture.updates.check()
            var openedURLs: [URL] = []
            let app = AppDelegate(
                store: fixture.store, onboarding: fixture.model, updates: fixture.updates,
                openURL: { openedURLs.append($0); return openedURLs.count > 1 }
            )
            let host = NSHostingView(rootView: DashboardView(store: fixture.store, app: app)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, Locale(identifier: "en_US"))
            )
            let window = makeWindow(host)
            defer { window.close() }
            window.setContentSize(NSSize(width: 440, height: 540))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await settle(host)
            let image = try capture(host)
            let setup = try text("Setup", in: image)
            let title = try text("ReviewQ v3.1.2 is out", in: image)
            let link = try text("View Updates", in: image)
            XCTAssertLessThan(title.maxY, setup.minY, "Updates belong below the unchanged toolbar.")
            XCTAssertGreaterThan(title.minY, 0.7)
            XCTAssertLessThan(title.maxX, link.minX)
            XCTAssertEqual(title.midY, link.midY, accuracy: 3 / host.bounds.height)
            XCTAssertLessThan(try text("By: Hritvik Patel", in: image).maxY, 0.1)
            try exportPreview(image, name: "update-banner-\(dark ? "dark" : "light")")

            try press("View Updates", in: host)
            XCTAssertEqual(openedURLs, [release.releaseURL])
            XCTAssertNotNil(app.actionError, "Browser failures must remain visible.")
            XCTAssertEqual(fixture.updates.bannerUpdate, release)
            try await settle(host)
            try press("View Updates", in: host)
            XCTAssertEqual(openedURLs, [release.releaseURL, release.releaseURL])
            XCTAssertNil(app.actionError)
            try await settle(host)
            let dismissY = rect(try text("View Updates", in: capture(host)), in: host).midY
            try press(at: NSPoint(x: host.bounds.maxX - 28, y: dismissY), in: host)
            XCTAssertNil(fixture.updates.bannerUpdate)
            XCTAssertEqual(fixture.updates.availableUpdate, release)
            XCTAssertEqual(fixture.store.snapshot, snapshot)
            XCTAssertEqual(fixture.store.menuBarTitle, menuTitle)
            let reopened = UpdateStore(currentVersion: "3.1.1", defaults: fixture.defaults, client: fixture.updateClient)
            XCTAssertNil(reopened.bannerUpdate)
            let checks = await fixture.updateClient.calls
            XCTAssertEqual(checks, 1, "Opening or dismissing a release must not make another update request.")
        }
    }

    func testSettingsCanManuallyCheckAndOpenADismissedUpdateAndShowFailures() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        let release = try AvailableUpdate(
            version: "3.1.2",
            releaseURL: XCTUnwrap(URL(string: "https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.1.2"))
        )
        await fixture.updateClient.setResult(.modified(release: release, entityTag: nil))
        var openedURLs: [URL] = []
        let host = NSHostingView(rootView: UpdateSettings(updates: fixture.updates, open: { openedURLs.append($0) })
            .padding(24)
            .frame(width: 560, height: 380, alignment: .topLeading)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        let window = makeWindow(host)
        defer { window.close() }
        window.setContentSize(NSSize(width: 560, height: 380))
        try await settle(host)
        try press("Check for Updates", in: host)
        try await settle(host)
        var checks = await fixture.updateClient.calls
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(fixture.updates.availableUpdate, release)
        fixture.updates.dismissUpdate()
        try await settle(host)
        try press("View Updates", in: host)
        XCTAssertEqual(openedURLs, [release.releaseURL])
        await fixture.updateClient.fail()
        try press("Check for Updates", in: host)
        try await settle(host)
        checks = await fixture.updateClient.calls
        XCTAssertEqual(checks, 2, "A manual check bypasses the successful daily interval.")
        XCTAssertNotNil(fixture.updates.errorMessage)
        try exportPreview(capture(host), name: "update-settings-failure")
        XCTAssertNotNil(try text("Could not check for ReviewQ updates.", in: capture(host), matchingPrefix: true))
        XCTAssertEqual(fixture.updates.availableUpdate, release)
        XCTAssertNil(fixture.store.snapshot, "Checking app updates must not fetch PRs.")
    }

    func testSettingsLogsInvalidReminderDraftOnlyOnSaveAndBeforeChangingSavedSettings() async throws {
        let fixture = try OnboardingFixture()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ReviewQ-settings-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            fixture.close()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove the test-owned settings diagnostics directory.") }
        }
        var settings = ReviewConfiguration()
        settings.sourceURLs = "https://dev.azure.com/example/Project"
        try fixture.store.save(settings)
        fixture.reminderCenter.status = .authorized
        try fixture.reminders.save(.init(isEnabled: true, weekdays: [2], times: [.init(hour: 10, minute: 30)]))
        await fixture.reminders.waitUntilIdle()
        let savedSettings = fixture.defaults.data(forKey: ReviewStore.settingsKey)
        let savedReminders = fixture.defaults.data(forKey: ReminderStore.settingsKey)
        let logger = DiagnosticLogger(directory: directory)
        logger.start()
        let app = AppDelegate(
            store: fixture.store, diagnostics: DiagnosticsStore(logger: logger, defaults: fixture.defaults),
            onboarding: fixture.model, updates: fixture.updates
        )
        let host = NSHostingView(rootView: SettingsView(store: fixture.store, app: app, loginItem: app.loginItem)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        let window = makeWindow(host)
        defer { window.close() }
        window.setContentSize(NSSize(width: 560, height: 700))
        window.appearance = NSAppearance(named: .aqua)
        try await settle(host)
        var views = [host as NSView]
        var scroller: NSScrollView?
        while let view = views.popLast() {
            if let scroll = view as? NSScrollView,
               let document = scroll.documentView, document.bounds.height > scroll.bounds.height {
                scroller = scroll
                break
            }
            views.append(contentsOf: view.subviews.reversed())
        }
        let scroll = try XCTUnwrap(scroller)
        let document = try XCTUnwrap(scroll.documentView)
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        var found = false
        for offset in stride(from: CGFloat(0), through: maximum + 250, by: 250) {
            let position = min(offset, maximum)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? position : maximum - position))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(host)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: capture(host)).perform([request])
            let labels = try XCTUnwrap(request.results).flatMap { $0.topCandidates(5).map { $0.string.lowercased() } }
            if labels.contains("mon"), labels.contains(where: { $0.contains("review reminders") }) {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "The Settings reminder controls must be reachable by scrolling.")
        guard found else { return }
        try press("Mon", in: host)
        try await settle(host)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func records() throws -> [DiagnosticRecord] {
            logger.flush()
            return try Data(contentsOf: directory.appendingPathComponent("warnings-errors.log"))
                .split(separator: 0x0a).map { try decoder.decode(DiagnosticRecord.self, from: Data($0)) }
        }
        XCTAssertEqual(try records().map(\.event), [.startup], "Passive draft validation must not emit warnings.")
        try press("Save and Refresh", in: host)
        try await settle(host)
        let failures = try records().filter { $0.event != .startup }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.event, .settingsFailed)
        XCTAssertEqual(failures.first?.operation, .reminders)
        XCTAssertEqual(failures.first?.reason, .invalidConfiguration)
        XCTAssertEqual(fixture.defaults.data(forKey: ReviewStore.settingsKey), savedSettings)
        XCTAssertEqual(fixture.defaults.data(forKey: ReminderStore.settingsKey), savedReminders)
        let calls = await fixture.loader.calls
        XCTAssertEqual(calls, 0)
    }

    func testNativeArchiveAndRestoreMoveCardsOutOfEveryActiveQueueInBothAppearances() async throws {
        for dark in [false, true] {
            for (section, followed, authored) in [
                ("Service", false, false), ("People you follow", true, false), ("I'm the Author", false, true)
            ] {
                let fixture = try OnboardingFixture()
                defer { fixture.close() }
                var settings = ReviewConfiguration()
                settings.sourceURLs = "https://dev.azure.com/example/Project"
                settings.followPeople = followed
                settings.followedAuthorEmails = followed ? "alex@example.com" : ""
                settings.showAuthoredPullRequests = authored
                let request = try archiveRequest(1, followed: followed, authored: authored)
                var snapshot = ReviewSnapshot(pullRequests: [request])
                snapshot.identityScope = String(repeating: "a", count: 64)
                try fixture.store.save(settings, verifiedSnapshot: snapshot)
                var openedURLs: [URL] = []
                let app = AppDelegate(
                    store: fixture.store, onboarding: fixture.model, updates: fixture.updates,
                    openURL: { openedURLs.append($0); return true }
                )
                let host = NSHostingView(rootView: DashboardView(store: fixture.store, app: app)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                )
                let window = makeWindow(host)
                defer { window.close() }
                window.setContentSize(NSSize(width: 440, height: 540))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                try await settle(host)
                try press(section, in: host, matchingSubstring: true)
                try await settle(host)
                let metadata = authored ? "2 Active Comments" : "First Review"
                let actionsY = rect(try text(metadata, in: capture(host)), in: host).midY
                try exportPreview(capture(host), name: "archive-action-\(dark ? "dark" : "light")-\(authored ? "authored" : followed ? "followed" : "assigned")")
                let archivePoint = NSPoint(x: host.bounds.maxX - (authored ? 73 : 129), y: actionsY)
                try assertWhiteActionIcon(at: archivePoint, in: host)
                try press(at: archivePoint, in: host)
                try await settle(host)
                XCTAssertNil(fixture.store.archiveErrorMessage)
                XCTAssertTrue(fixture.store.activePullRequests.isEmpty)
                XCTAssertEqual(fixture.store.archivedPullRequests, [request])
                XCTAssertEqual(fixture.store.menuBarTitle, " 0")
                XCTAssertTrue(openedURLs.isEmpty, "Archive must not fall through to a browser or assistant action.")
                XCTAssertEqual(fixture.store.snapshot, snapshot)
                try press("Archives", in: host, matchingSubstring: true)
                try await settle(host)
                try exportPreview(capture(host), name: "archives-\(dark ? "dark" : "light")-\(authored ? "authored" : followed ? "followed" : "assigned")")
                let restoreY = rect(try text(metadata, in: capture(host)), in: host).midY
                try press(at: NSPoint(x: 150, y: restoreY + (host.isFlipped ? 26 : -26)), in: host)
                XCTAssertEqual(openedURLs, [request.url])
                let restorePoint = NSPoint(x: host.bounds.maxX - 73, y: restoreY)
                try assertWhiteActionIcon(at: restorePoint, in: host)
                try press(at: restorePoint, in: host)
                try await settle(host)
                XCTAssertEqual(fixture.store.activePullRequests, [request])
                XCTAssertTrue(fixture.store.archivedPullRequests.isEmpty)
                XCTAssertEqual(fixture.store.menuBarTitle, followed || authored ? " 0" : " 1")
                XCTAssertEqual(openedURLs, [request.url], "Restore must not invoke the row's browser action.")
                XCTAssertFalse(fixture.store.changes.hasChanges)
                let calls = await fixture.loader.calls
                XCTAssertEqual(calls, 0)
            }
        }
    }

    func testArchivesRemainBelowAllOtherSectionsAndFitWithinTheDashboard() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var settings = ReviewConfiguration()
        settings.sourceURLs = "https://dev.azure.com/example/Project"
        settings.followPeople = true
        settings.followedAuthorEmails = "alex@example.com"
        settings.showAuthoredPullRequests = true
        let archived = try archiveRequest(4)
        var snapshot = ReviewSnapshot(pullRequests: [
            try archiveRequest(1), try archiveRequest(2, followed: true),
            try archiveRequest(3, authored: true), archived
        ])
        snapshot.identityScope = String(repeating: "a", count: 64)
        try fixture.store.save(settings, verifiedSnapshot: snapshot)
        fixture.store.archive(archived)
        let app = AppDelegate(store: fixture.store, onboarding: fixture.model, updates: fixture.updates)
        let host = NSHostingView(rootView: DashboardView(store: fixture.store, app: app)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        let window = makeWindow(host)
        defer { window.close() }
        window.setContentSize(NSSize(width: 440, height: 540))
        window.appearance = NSAppearance(named: .aqua)
        try await settle(host)
        let image = try capture(host)
        try exportPreview(image, name: "archive-section-order")
        let archive = try text("Archives", in: image, matchingSubstring: true)
        let author = try text("I'm the Author", in: image, matchingSubstring: true)
        let people = try text("People you follow", in: image, matchingSubstring: true)
        let repository = try text("Service", in: image)
        XCTAssertLessThan(archive.maxY, author.minY)
        XCTAssertLessThan(author.maxY, people.minY)
        XCTAssertLessThan(people.maxY, repository.minY)
        XCTAssertGreaterThan(archive.minY, try text("By: Hritvik Patel", in: image).maxY)
        XCTAssertEqual(host.bounds.size, NSSize(width: 440, height: 540))
    }

    private func archiveRequest(
        _ number: Int, followed: Bool = false, authored: Bool = false
    ) throws -> ReviewPullRequest {
        ReviewPullRequest(
            number: number, title: "Archive fixture \(number)", author: "Fixture author", organization: "example",
            project: "Project", repository: "Service", repositoryID: "service-id",
            createdAt: Date(timeIntervalSince1970: TimeInterval(number)),
            url: try AzureDevOpsURL.make(
                organization: "example", path: ["Project", "_git", "service-id", "pullrequest", String(number)]
            ),
            isRequired: false, isDraft: false, reviewStage: .firstReview, isFollowedOnly: followed,
            authoredStatus: authored ? AuthoredPullRequestStatus(activeCommentCount: 2, hasRequiredApprovals: false) : nil
        )
    }

    func testRelaunchedDashboardShowsCachedRepositoriesAndUpdateTimeWhileRefreshing() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        var configuration = ReviewConfiguration()
        configuration.sourceURLs = "https://dev.azure.com/example/Project"
        try fixture.store.save(configuration)
        let request = ReviewPullRequest(
            number: 1, title: "Synthetic saved review", author: "Synthetic author",
            organization: "example", project: "Project", repository: "Service", repositoryID: "service-id",
            createdAt: .distantPast,
            url: try XCTUnwrap(URL(string: "https://dev.azure.com/example/Project/_git/service-id/pullrequest/1")),
            isRequired: false, isDraft: false, reviewStage: .firstReview
        )
        var cached = ReviewSnapshot(pullRequests: [request], updatedAt: .now.addingTimeInterval(-90))
        let scope = String(repeating: "a", count: 64)
        cached.identityScope = scope
        ReviewQueueCache(defaults: fixture.defaults).save(cached, configuration: configuration)
        let loader = CachedStartupLoader(scope: scope)
        let store = ReviewStore(defaults: fixture.defaults, keychain: fixture.keychain, loader: loader)
        defer { store.stop() }
        let app = AppDelegate(store: store, onboarding: fixture.model, updates: fixture.updates)
        let host = NSHostingView(rootView: DashboardView(store: store, app: app)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        let window = makeWindow(host)
        defer { window.close() }
        window.setContentSize(NSSize(width: 440, height: 540))
        let refresh = Task { await store.refresh() }
        await loader.waitUntilStarted()
        try await settle(host)
        let image = try capture(host)
        XCTAssertEqual(store.snapshot, cached)
        XCTAssertTrue(store.isRefreshing)
        let refreshingToolbar = try toolbarTargets(in: host)
        XCTAssertLessThan(try text("Updated", in: image, matchingPrefix: true).maxY, 0.1)
        XCTAssertGreaterThan(try text("Service", in: image).midY, 0.1)
        try exportPreview(image, name: "cached-startup-light")
        var next = ReviewSnapshot(pullRequests: [])
        next.identityScope = scope
        await loader.finish(next)
        await refresh.value
        XCTAssertEqual(store.snapshot, next)
        XCTAssertFalse(store.isRefreshing)
        try await settle(host)
        let refreshedToolbar = try toolbarTargets(in: host)
        for (refreshing, refreshed) in zip(refreshingToolbar, refreshedToolbar) {
            XCTAssertEqual(refreshing.x, refreshed.x, accuracy: 1)
        }
    }

    func testSetupWindowReusesAndResumesWithoutLosingAnOpenSettingsWindow() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        let app = AppDelegate(store: fixture.store, onboarding: fixture.model, updates: fixture.updates)
        defer { closeWindows() }
        app.showSettings()
        let settings = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "ReviewQ Settings" && $0.isVisible })
        XCTAssertNotNil(app.showOnboarding())
        XCTAssertTrue(settings.isVisible)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertFalse(NSApplication.shared.windows.contains { $0.title == "ReviewQ Setup" && $0.isVisible })
        settings.close()
        XCTAssertNil(app.showOnboarding())
        let first = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "ReviewQ Setup" && $0.isVisible })
        XCTAssertNil(app.showOnboarding())
        XCTAssertEqual(NSApplication.shared.windows.filter { $0.title == "ReviewQ Setup" && $0.isVisible }.count, 1)
        await fixture.model.advance()
        fixture.model.draft.sourceURLs = "https://dev.azure.com/example/Project"
        first.close()
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertNil(app.showOnboarding())
        let reopened = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == "ReviewQ Setup" && $0.isVisible })
        XCTAssertFalse(first === reopened)
        XCTAssertEqual(fixture.model.step, .sources)
        XCTAssertEqual(fixture.model.draft.sourceURLs, "https://dev.azure.com/example/Project")
        app.showSettings()
        XCTAssertTrue(reopened.isVisible, "Settings must not create a competing settings editor during setup.")
        XCTAssertFalse(NSApplication.shared.windows.contains { $0.title == "ReviewQ Settings" && $0.isVisible })
    }

    func testFirstLaunchPresentsSetupAndCompletionOpensTheQueueButConfiguredUsersSkipIt() async throws {
        let fixture = try OnboardingFixture()
        defer { fixture.close() }
        let diagnostics = DiagnosticsStore(logger: .disabled, defaults: fixture.defaults)
        let app = AppDelegate(
            store: fixture.store, diagnostics: diagnostics,
            shortcutRegistrar: SetupShortcutRegistrar(), onboarding: fixture.model, updates: fixture.updates
        )
        defer { app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); closeWindows() }
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertTrue(NSApplication.shared.windows.contains { $0.title == "ReviewQ Setup" && $0.isVisible })
        await fixture.reach(.ready)
        XCTAssertTrue(fixture.model.complete())
        app.finishOnboarding()
        XCTAssertFalse(NSApplication.shared.windows.contains { $0.title == "ReviewQ Setup" && $0.isVisible })
        XCTAssertNil(app.actionError, "A native menu-bar queue must be available after finishing.")
        app.closePopover()
        let existing = fixture.newModel()
        XCTAssertFalse(existing.shouldPresentAutomatically)
        let restored = AppDelegate(
            store: fixture.store, diagnostics: diagnostics,
            shortcutRegistrar: SetupShortcutRegistrar(), onboarding: existing, updates: fixture.updates
        )
        restored.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertFalse(NSApplication.shared.windows.contains { $0.title == "ReviewQ Setup" && $0.isVisible })
        restored.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    private func makeWindow<Content: View>(_ host: NSHostingView<Content>) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false,
            screen: NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ host: NSView) async throws {
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.displayIfNeeded()
    }

    private func capture(_ host: NSView) throws -> CGImage {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.cgImage)
    }

    private func assertWhiteActionIcon(
        at point: NSPoint, in host: NSView, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let bounds = NSRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        var whitePixels = 0
        var coloredPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let low = min(color.redComponent, color.greenComponent, color.blueComponent)
                let high = max(color.redComponent, color.greenComponent, color.blueComponent)
                if low > 0.75, high - low < 0.08 { whitePixels += 1 }
                if high - low > 0.2 { coloredPixels += 1 }
            }
        }
        let pixels = Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        XCTAssertGreaterThan(Double(whitePixels) / pixels, 0.4, "Action icons need a white backplate, including when inactive.", file: file, line: line)
        XCTAssertGreaterThan(Double(coloredPixels) / pixels, 0.02, "The symbol must stay colored on white.", file: file, line: line)
    }

    private func toolbarTargets(in host: NSView) throws -> [NSPoint] {
        let label = try text("Setup", in: capture(host))
        XCTAssertGreaterThan(label.minY, 0.8, "Setup belongs in the header, not the footer.")
        let setup = rect(label, in: host)
        let quitX = host.bounds.maxX - 28
        let settingsX = quitX - 45
        let refreshX = settingsX - 34
        XCTAssertLessThan(setup.maxX, refreshX - 12, "Setup must fit before Refresh without overlap.")
        return [
            NSPoint(x: setup.midX, y: setup.midY),
            NSPoint(x: refreshX, y: setup.midY),
            NSPoint(x: settingsX, y: setup.midY),
            NSPoint(x: quitX, y: setup.midY)
        ]
    }

    private func text(
        _ title: String, in image: CGImage, matchingPrefix: Bool = false, matchingSubstring: Bool = false,
        topCandidateOnly: Bool = false
    ) throws -> CGRect {
        let bandHeight = image.height / 5
        let height = CGFloat(bandHeight) / CGFloat(image.height)
        var regions: [(CGImage, CGFloat, CGFloat)] = [(image, 1, 0)]
        // Magnify small header/footer labels without the host-dependent accurate model under Rosetta.
        for header in [false, true] {
            let band = try XCTUnwrap(image.cropping(to: CGRect(
                x: 0, y: header ? 0 : image.height - bandHeight, width: image.width, height: bandHeight
            )))
            let context = try XCTUnwrap(CGContext(
                data: nil, width: band.width * 2, height: band.height * 2,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .high
            context.draw(band, in: CGRect(x: 0, y: 0, width: band.width * 2, height: band.height * 2))
            regions.append((try XCTUnwrap(context.makeImage()), height, header ? 1 - height : 0))
        }
        var visibleText: [String] = []
        var bounds: CGRect?
        for (region, height, offset) in regions {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: region).perform([request])
            let results = try XCTUnwrap(request.results)
            if let match = results.first(where: { observation in
                observation.topCandidates(topCandidateOnly ? 1 : 5).contains {
                    if matchingPrefix { return $0.string.lowercased().hasPrefix(title.lowercased()) }
                    if matchingSubstring { return $0.string.lowercased().contains(title.lowercased()) }
                    return $0.string.lowercased() == title.lowercased()
                }
            }) {
                bounds = CGRect(
                    x: match.boundingBox.minX, y: offset + match.boundingBox.minY * height,
                    width: match.boundingBox.width, height: match.boundingBox.height * height
                )
                break
            }
            visibleText.append(contentsOf: results.compactMap { $0.topCandidates(1).first?.string })
        }
        return try XCTUnwrap(bounds, "Missing \(title); visible text: \(visibleText).")
    }

    private func rect(_ bounds: CGRect, in host: NSView) -> NSRect {
        NSRect(
            x: bounds.minX * host.bounds.width,
            y: (host.isFlipped ? 1 - bounds.maxY : bounds.minY) * host.bounds.height,
            width: bounds.width * host.bounds.width, height: bounds.height * host.bounds.height
        )
    }

    private func press(_ title: String, in host: NSView, matchingSubstring: Bool = false) throws {
        let bounds = try text(title, in: capture(host), matchingSubstring: matchingSubstring)
        let button = rect(bounds, in: host)
        try press(at: NSPoint(x: button.midX, y: button.midY), in: host)
    }

    private func press(at point: NSPoint, in host: NSView) throws {
        let location = host.convert(point, to: nil)
        let window = try XCTUnwrap(host.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )))
        }
    }

    private func exportPreview(_ image: CGImage, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["REVIEWQ_ONBOARDING_PREVIEWS"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func closeWindows() {
        for window in NSApplication.shared.windows where
            ["ReviewQ Setup", "ReviewQ Settings", "ReviewQ Diagnostics"].contains(window.title) {
            window.close()
        }
    }
}

private struct ReminderSettingsHarness: View {
    @ObservedObject var model: OnboardingStore
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ReminderSettings(
                configuration: $model.reminderDraft, reminders: model.reminders,
                saveHint: "Your schedule is saved when you finish setup.", openSystemSettings: openSettings
            )
            Button("Save reminders") {
                do { try model.reminders.save(model.reminderDraft) }
                catch { XCTFail("Could not save reminder draft: \(error)") }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private final class SetupShortcutRegistrar: GlobalShortcutRegistering {
    func register(action: @escaping @MainActor () -> Void) throws {}
    func unregister() throws {}
}

private actor CachedStartupLoader: ReviewLoading {
    let scope: String
    private var pending: CheckedContinuation<ReviewSnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(scope: String) { self.scope = scope }
    func invalidateIdentityCache() {}

    func load(configuration: ReviewConfiguration) async throws -> ReviewSnapshot {
        try await load(configuration: configuration, onIdentityScope: { _ in })
    }

    func load(
        configuration: ReviewConfiguration, onIdentityScope: @Sendable (String) async -> Void
    ) async throws -> ReviewSnapshot {
        await onIdentityScope(scope)
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ snapshot: ReviewSnapshot) {
        pending?.resume(returning: snapshot)
        pending = nil
    }
}
