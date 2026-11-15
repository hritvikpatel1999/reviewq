# PR Context: ReviewQ v3.1.0

## Summary

Version 3.1.0 / build 7 adds changes-since-refresh dots, a verified and resumable first-run setup,
and an account-scoped display cache that keeps the previous queue visible during startup loading.
It also moves **Run Setup** to the queue footer beside the update time and uses the native Settings
accent. This release builds on v3.0.0; existing configuration, authentication, and read-only workflows
remain compatible.

## Key Decisions

| Decision | Rationale | Alternatives considered | Impact and tradeoffs |
| --- | --- | --- | --- |
| Compare the latest two successful refreshes, not unread state. | The requested indicators describe changes from the previous network refresh, regardless of whether a PR was opened. | Clearing dots on browser/assistant actions was explicitly excluded. | Each successful refresh replaces dots; failure and cancellation retain them. Removed PRs mark affected sections without inventing cards. |
| Restore a queue only after the existing credential step supplies a matching account scope. | A relaunch should show prior data while loading without exposing another account's queue. | Showing an unscoped cache before authentication would break account isolation. | No extra credential or HTTP request; authentication failure before scope acquisition cannot reveal the cache. |
| Persist a bounded display-only snapshot in local preferences. | Preserve repository layout, badges, the original update time, and the next refresh's comparison baseline. | Always showing the initial empty/loading state was the behavior being replaced. Other storage alternatives were not documented. | Local data is unencrypted; limits are 2 MiB, 4,096 PRs, and less than seven days. Oversized queues are never truncated into a partial cache. |
| Reuse compact fingerprints of already fetched responses. | Detect PR/reviewer/discussion changes without additional Azure DevOps calls or timers. | Fetching more resources solely for dots would increase request volume. | Comparisons add local work; response ordering and refresh time do not produce false changes. No performance benchmark is claimed. |
| Require verified access before finishing native setup, and preserve existing users' settings. | First-run guidance must not report a failed connection as a ready empty queue or discard an open Settings draft. | Mandatory re-onboarding of configured users was excluded. | Non-secret progress resumes, but PATs and verification do not persist in the draft. A fresh verified queue is reused instead of immediately re-fetched. |
| Keep the existing bundle, Keychain, settings, and log identities. | Updating should retain saved configuration and credentials. | Not documented. | Bundle ID stays `dev.prbar.app`; the new cache and onboarding keys do not replace existing settings. |

## Key Flows

### Relaunch and refresh

1. [AzureDevOpsReviewLoader](../../Sources/ReviewQCore/AzureDevOpsClient.swift) acquires credentials
   through the existing authentication path and invokes the identity-scope callback before its
   Azure DevOps HTTP requests.
2. [ReviewStore](../../Sources/ReviewQCore/ReviewStore.swift) rejects obsolete generations and
   cancelled work. A changed account scope clears prior display/cache state; a matching scope
   can restore the validated [ReviewQueueCache](../../Sources/ReviewQCore/ReviewQueueCache.swift).
3. The normal repository/optional sections appear with their original **Updated ... ago** time
   while the header refresh indicator remains active. Old dots are not persisted.
4. A complete accepted success compares against the restored baseline, replaces the display and
   dots, and saves the new snapshot. Successful empty queues are valid cache entries.
5. Failed, cancelled, or superseded requests cannot overwrite the matching last-successful cache.
   Failures remain visible rather than becoming a successful empty queue.
6. Saving Settings clears the previous baseline/cache. Deleting the active PAT clears its cache.
   The first successful refresh after upgrading seeds persistence.

### Change indicators

1. [ReviewChanges](../../Sources/ReviewQCore/ReviewChanges.swift) compares stable PR IDs, display
   fields, and compact fingerprints built from the existing PR/discussion/policy responses.
2. New, updated, moved, and removed PRs propagate to the menu bar and affected repository or optional
   section. Only existing new/updated cards receive PR dots.
3. Browser actions, assistant actions, and expanding sections leave dots untouched. The next
   successful refresh determines the replacement indicators.

### First-run setup and replay

1. New installations open six native screens: Welcome, sources, connection, optional companions,
   preferences, and ready. Configured installations bypass automatic setup.
2. Connection testing uses the existing read-only loader with draft settings. Changed request-affecting
   choices must be checked before completion; local display/assistant preferences need no duplicate
   connection request.
3. Closing setup keeps non-secret preferences and progress, but clears an unsaved PAT and verification.
   Reopening requires verification again.
4. Completing setup saves settings and any new PAT through the existing Keychain path, then installs
   the verified snapshot. An expired setup result triggers normal refresh instead of postponing it.
5. **Run Setup** is in the bottom-right queue footer, even before a snapshot exists. Replaying starts
   from the latest saved preferences, refuses to discard an open Settings editor, and offers
   **Keep existing settings**.

## FAQs

### What is cached, and can it expose credentials or discussions?

The cache contains PR titles, author display names, repository/project names, canonical browser
links, timestamps, display flags/badges, compact change fingerprints, and hashed scopes. It is local
and **unencrypted**. It does not contain PATs, access tokens, descriptions, comment bodies, or assistant
prompts, and it is not included in diagnostic exports. See
[cached startup details](../../README.md#cached-startup-queue) for retention and invalidation rules.

### Does this add network requests or permissions?

Dots and startup restoration add no HTTP requests, authentication requests, or polling timers.
Setup's explicit connection tests use the existing loader; enabling optional authored/followed
queues retains their existing request behavior. Scout automation's Accessibility button is optional.
ReviewQ does not request microphone or Screen Recording permission. VS Code permissions remain
controlled by the user's profile and organization; setup does not enable Allow All.

### What remains unchanged?

Azure CLI/PAT authentication, read-only API scopes, repository ordering, review-stage labels,
assistant launch behavior, default-off optional queues, and existing Settings/Diagnostics remain.
The bundle identifier, Keychain service, `reviewConfiguration` key, identity cache, and log location
are unchanged. Both release architectures continue to require macOS 14 or later and use ad-hoc
signatures, not Developer ID signing or notarization.

### How was this validated?

The release regression profile passed **233 tests on arm64 and 233 on Intel/Rosetta x86_64**,
excluding the same five established host-dependent OCR checks (three dashboard captions and two
follow-settings captions). No new cache, onboarding, or change-indicator tests were excluded;
all native Settings editing tests passed.

Focused tests cover callback order and unchanged request counts, cache round trips and malformed
data, expiry/size limits, account/preference isolation, failure/cancellation/supersession preservation,
successful empty queues, verified setup handoff, and PAT deletion. Native hosted-window tests verify
cached repository content, the old update time, the active refresh indicator, footer placement,
blue setup styling, replay safety, and dots without extra rows. These tests use synthetic data; no
live Azure DevOps validation or measured latency claim is made.

Both production architectures and their extracted ZIP payloads passed strict/deep signature
verification, architecture and version/build checks, stable bundle identity, macOS 14 minimum,
icon-resource equality, compiled-binary UUID equality, and archive checksum verification.

### How can this be diagnosed or rolled back?

Existing diagnostics expose safe queue-cache outcomes without cached titles, URLs, or credentials.
Settings save intentionally resets the cache/baseline; a fresh successful refresh recreates it.
After quitting the current app, the prior
[v3.0.0 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.0.0) can be used without
deleting saved settings or Keychain credentials. The prior version does not use the new display-cache
or setup-progress keys.
