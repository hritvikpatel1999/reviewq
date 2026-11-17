# PR Context: Release ReviewQ v3.2.0

## Summary

Release version 3.2.0 / build 9 adds a dismissible **View Updates** banner and a manual Settings
check, backed by cached public GitHub release metadata. Installation remains manual; GitHub
pull-request integration and automatic downloads/installations are not included.

## Key Decisions

| Decision | Rationale | Alternatives considered | Impact and tradeoffs |
| --- | --- | --- | --- |
| Check when due on launch, wake, and queue opening, with a persistent 24-hour success interval. | Updates should be discoverable without coupling release checks to frequent PR refreshes. | A daily timer was discussed; opportunistic checks avoid a separate background service. | No checks run while ReviewQ is closed. Automatic failures use exponential backoff; manual checks still honor server deadlines. |
| Use the public latest-release API with a separate observable store and no credentials. | Release discovery does not depend on Azure DevOps sign-in and needs no backend or added dependency. | A hosted update service was unnecessary for this scope. | Anonymous requests share GitHub's per-IP limits; ETags reduce response size, not guaranteed rate-limit consumption. |
| Open the official release page instead of installing updates. | The user selected **View Updates** and manual installation. | Sparkle and automatic installation were discussed as future work. | No executable download, replacement, or relaunch. The existing ad-hoc signing/notarization limitation remains. |
| Persist dismissal for only the offered version. | Closing the banner should not hide later releases. | Globally disabling update notifications would hide future versions. | Settings retains the release link; upgrading suppresses equal or older versions automatically. |
| Validate numeric stable versions, official release URLs, and restored metadata. | A cached or remote release must not become an arbitrary browser destination or false success. | No additional versioning dependency was needed for the repository's three-component stable versions. | Prereleases, drafts, malformed versions, and nonofficial/mismatched release URLs are not offered. |

## Key Flows

### Discovering an update

1. Launch, wake, or successful queue presentation asks the independent update store to check if due.
   Concurrent triggers share one request. PR refreshes never trigger release checks.
2. The store restores validated release metadata, ETag, schedule, and dismissal before contacting
   the public GitHub latest-release endpoint without Authorization or Azure DevOps data.
3. A valid 200 response replaces cached metadata; a valid conditional 304 retains it. Success
   schedules the next automatic check for 24 hours later.
4. A numerically newer stable release appears beneath the unchanged toolbar. Browser-open failure
   uses the existing visible action error; success opens the release page for manual installation.
5. Dismissal persists that version only. The queue snapshot, pending count, and change indicators
   are unaffected.

### Manual checks and failures

1. Settings shows the installed version, check action, available release link, and last success.
   A dismissed release remains available there without saving or discarding a Settings draft.
2. A manual check bypasses the normal interval and automatic failure backoff, but not GitHub's
   persisted retry-not-before deadline.
3. Failure preserves the release and last success, shows an explicit error, records a safe
   diagnostic category, and backs off automatic retries. It never becomes an up-to-date result.
4. Termination cancels the scheduled check; cancelled results are neither published nor cached.
   Invalid persisted metadata is cleared with an explicit diagnostic.

## FAQs

### What remains unchanged?

Azure DevOps remains the only PR provider. Existing authentication, Keychain service, bundle identity
`dev.prbar.app`, settings, queue and identity caches, shortcut/popover behavior, assistant actions,
and green changes-since-refresh semantics are preserved.

### What leaves the device?

Only a normal public HTTPS release-metadata request and optional ETag are sent to GitHub.
No Azure DevOps credentials, PR data, assistant instructions, or GitHub token are included.
The new local `reviewAppUpdates` preference stores only release metadata and check/dismissal state.

### How was this validated?

Before release preparation, 81 selected regression tests passed on Apple Silicon and Intel/Rosetta.
These include all 13 core update tests, native light/dark banner actions, Settings failure rendering,
lifecycle scheduling, PR-refresh independence, shared Azure transport, diagnostics, and onboarding.
A live credential-free check retrieved the official v3.1.1 release and its conditional follow-up
returned 304 Not Modified.

The full release profile subsequently ran 250 tests per architecture, retaining the same five
documented OCR exclusions. On each architecture, 248 passed and these two unchanged tests failed
with three assertions:

- `NativeEditMenuTests/testMultilineEditorSelectsCopiesAndPastesExactText`
- `NativeEditMenuTests/testSingleLineFieldEditorSelectsCopiesAndPastesExactText`

The identical failures reproduced on an isolated, unchanged v3.1.1 baseline (233/235 passed).
Running the native editing suite separately did not resolve them on this host. They are reported
as an existing validation limitation, not hidden by additional exclusions or changes to the tests.
All 15 new update tests and the expanded lifecycle/shortcut regression passed on both architectures.

Both packaged apps and extracted ZIP payloads passed strict/deep signature, architecture, version
3.2.0/build 9, minimum macOS 14, bundle-identity, icon-resource, compiled-UUID, and checksum checks.
The running default bundle was not replaced or relaunched. Intel validation used Rosetta, not
physical Intel hardware; no live Azure DevOps or desktop-automation validation is claimed.

### How can this be diagnosed or rolled back?

Use the `appUpdates` operation and `updateCheck*`/`updateCache*` event categories in Diagnostics.
Failures do not log response bodies or arbitrary release URLs. Quit ReviewQ and restore the
v3.1.1 bundle to roll back; existing settings and credentials need no migration reversal.
Downloads remain ad-hoc signed rather than Developer ID signed or Apple-notarized.
