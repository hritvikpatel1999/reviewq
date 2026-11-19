# PR Context: Release ReviewQ v4.0.0

## Summary

Version 4.0.0 / build 11 adds opt-in scheduled local review reminders in Setup and Settings, plus
more complete failure diagnostics. Notification clicks explicitly open the queue, including after
a cold launch. Existing Azure DevOps queues, archives, credentials, and update behavior are preserved.

## Key Decisions

| Decision | Rationale | Alternatives considered | Impact and tradeoffs |
| --- | --- | --- | --- |
| Use opt-in, generic local notifications on selected weekdays and times. | The requested reminder is a nudge to open ReviewQ, not a notification containing live PR data. | Background PR polling and server-driven notifications were outside the requested scope. | macOS owns delivery, including while ReviewQ is closed; Focus, sleep, and notification settings can delay or suppress banners. |
| Derive reminders per day from up to eight distinct time rows. | One editable schedule avoids conflicting time and frequency settings and bounds weekly requests at 56. | A separate notifications-per-day counter was considered in the design discussion. | The initial suggestion is Monday-Friday at 10:30 and 15:30, with sound off; no schedule is enabled automatically. |
| Persist reminders separately and preserve Setup/Settings drafts. | Notification permission is independent of Azure DevOps authentication and approving permission must not silently save a draft. | Coupling schedules to account configuration or applying every edit immediately was not chosen. | The versioned, bounded `reviewReminders` preference contains no PR/account data. Old Setup drafts without reminder choices remain readable. |
| Explicitly open the queue and wait for the status-item window on cold launch. | The ordinary menu action toggles and Finder reopen opens Settings, neither of which matches a notification click. | Reusing either existing action would produce the wrong UX. | Cached content stays visible while normal coalesced refresh runs; unrelated notifications and dismissals do not activate the queue. |
| Retain only fixed diagnostic categories and safe scalar error details. | Failures must be actionable with verbose logging off without collecting private native descriptions, CLI output, or notification payloads. | Arbitrary messages and `NSError.userInfo` are deliberately excluded. | Reminder failure stages, native/CLI codes, and assistant durations survive normalization; cancellation stays informational and passive validation remains unlogged. |

## Key Flows

### Configure and apply reminders

1. Setup Preferences and Settings share the same day/time/sound controls. Enabling or explicitly
   allowing notifications can request macOS permission, but does not commit the draft.
2. Save and Refresh or Open my queue validates and persists the desired schedule separately from
   account settings. Setup reminder edits do not invalidate a verified Azure DevOps connection.
3. A serialized worker reads authorization and owned pending identifiers, then reconciles only
   ReviewQ reminder requests. Unchanged schedules are not rewritten on every activation.
4. Weekly requests use floating local calendar components, generic text, and optional sound.
   Explicit tests deliver immediately without enabling or saving the schedule.
5. Denial or failure remains visible. Partial scheduling attempts roll back, and revisions prevent
   an in-flight old schedule from surviving a subsequent opt-out. Quitting does not cancel requests.

### Open the queue from a notification

1. The notification delegate is registered before launch finishes and accepts only ReviewQ's
   identifiers with the default notification action.
2. A warm response opens rather than toggles the queue. A cold response remains pending until
   the status-item window is visible and has usable geometry.
3. The app activates the queue and requests the ordinary coalesced refresh, retaining cached PRs.
   It does not open Settings, discard drafts, or react to unrelated notifications/dismissals.

### Diagnose a failure

1. Reminder errors preserve a safe diagnostic value through authorization, scheduling, and test
   wrappers, yielding one phase-specific terminal event instead of losing the native code.
2. Settings logs rejected reminder drafts only on Save, before other settings are persisted.
   Native activation/shortcut parsing, browser callbacks, and Accessibility remediation failures
   also reach the structured logger.
3. Assistant failures retain elapsed time, command exit codes, and fixed Scout failure reasons.
   Known cancellation is informational, not a default-on warning.
4. Existing owner-only, bounded JSONL storage and sanitized ZIP export preserve the allowed fields.
   A failed disk sink still surfaces in Diagnostics and unified logging without private descriptions.

## FAQs

### Does this add background PR polling, a backend, or a new provider?

No. Reminders neither fetch nor contain PR data. Azure DevOps remains the only PR provider;
GitHub remains the public app-release/update source. Notification clicks use the existing refresh
path. Automatic app replacement is still not implemented.

### What permission and compatibility boundaries apply?

macOS notification permission is requested only after an explicit reminder action. Denial does not
block setup or the queue. A packaged app is required; SwiftPM tests use injected notification
backends and do not request real permission. The minimum remains macOS 14, with the same bundle
identifier, Keychain service, account configuration, archives, and cache scope.

### How was this validated?

Before release preparation, all 103 affected-path tests passed on Apple Silicon and on
Intel/Rosetta. Coverage includes scheduling/rollback/opt-out races, draft persistence, native
controls in both appearances, exact add/remove-time preservation, cold/warm queue activation,
default-on failure logging, native callback errors, and private-data exclusion from logs/exports.
No real notification permission, live Azure DevOps account, or real assistant/browser launch is
used by these tests. Intel validation uses Rosetta rather than physical Intel hardware.

The full release profile ran 281 tests per architecture with the same five documented OCR
exclusions: 279 passed on each architecture. These two unchanged clipboard tests failed with
three assertions on both architectures:

- `NativeEditMenuTests/testMultilineEditorSelectsCopiesAndPastesExactText`
- `NativeEditMenuTests/testSingleLineFieldEditorSelectsCopiesAndPastesExactText`

Both failures reproduced with the same assertions on an isolated, untouched v3.3.0 worktree on
Apple Silicon and Intel/Rosetta. They remain reported failures, not new exclusions. All 22 added
tests and every other included test passed. The previously reported People-section OCR failure
did not recur in this release run.

Both packaged apps and extracted ZIP payloads passed strict/deep signature, architecture,
version 4.0.0/build 11, minimum macOS 14 (plist and executable), bundle-identity, icon-resource,
notification-framework linkage, compiled-UUID, and SHA-256 checks. The running default bundle
was not replaced or relaunched. Downloads are ad-hoc signed, not Developer ID signed/notarized.

### How can this be diagnosed or rolled back?

Open Settings > Diagnostics. Reminder failures use the `reminders` operation with separate
authorization, scheduling, and test-failure events; available native numeric codes survive without
descriptions or `NSError` payloads. Verbose mode is optional and is not required for failures.

To roll back, disable reminders and save before quitting v4, then restore the v3.3.0 bundle.
Quitting alone intentionally leaves OS-scheduled requests in place, and v3.3.0 cannot manage the
new reminder preference. Existing account settings and credentials need no migration reversal.
Downloads remain ad-hoc signed, not Developer ID signed or Apple-notarized; do not disable macOS
security protections.
