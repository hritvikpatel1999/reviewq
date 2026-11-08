# ReviewQ

*Your reviews. One queue.*

A standalone native macOS menu-bar app for Azure DevOps pull requests that need your review.
ReviewQ does not require SwiftBar, LeetBar, or AppFoundations at build time or runtime.
Version 1 supports **Azure DevOps only**. GitHub pull-request integration is planned for a
future version, not included in this release.

## Features

- Native pull-request icon with the pending-review count.
- Newest-first repository dropdowns with pending counts, author, age, review-stage labels, and one-click browser links.
- Multiple Azure DevOps organizations and projects.
- Automatic refresh (1, 5, 15, or 30 minutes), manual refresh, and refresh after wake.
- Microsoft Entra authentication through your existing Azure CLI sign-in.
- Optional personal access token stored only in macOS Keychain.
- Settings, optional draft PRs, and launch at login.
- Visible authentication/network errors; failed refreshes never masquerade as an empty queue.
- Local diagnostics with opt-in verbose logging, correlated request outcomes, and private ZIP exports.

## Download version 1

Download from the [ReviewQ v1.0.0 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v1.0.0).
The repository is private, so you must sign into a GitHub account with access.

Requires **macOS 14 or later**:

- **Apple Silicon** (M-series Macs): `ReviewQ-1.0.0-macos-arm64.zip`.
- **Intel** Macs: `ReviewQ-1.0.0-macos-x86_64.zip`.
- `SHA256SUMS.txt` contains SHA-256 checksums for both ZIPs.

If you download both ZIPs and the checksum file into the same folder, verify them with:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Extract the matching ZIP and move `ReviewQ.app` into Applications. Quit any previous PRBar or
ReviewQ instance before opening it. The app has no Dock icon; use its pull-request menu-bar icon.
Configure Azure DevOps as described below. Azure CLI is installed separately if you choose that
authentication method; a PAT does not require Azure CLI.

**Signing limitation:** version 1 builds are ad-hoc signed for integrity, not Developer ID signed
or Apple-notarized. macOS may warn about or block downloaded copies. Do not disable Gatekeeper or
other macOS security protections. Only use macOS's per-app approval if you have verified the
download and trust it; otherwise build locally or wait for a Developer ID signed/notarized release.
Checksums verify that your download matches the release asset, not Apple's approval of its publisher.
Intel builds are exercised under Rosetta on Apple Silicon, not on physical Intel hardware.

## Build and open

Requires **macOS 14+** and **Xcode 16+** (Swift 6). There are no third-party package dependencies.

```sh
git clone https://github.com/hritvikpatel1999/reviewq.git
cd reviewq
swift test
sh scripts/build-app.sh
open dist/ReviewQ.app
```

The app has no Dock icon. Click its pull-request icon in the menu bar. First launch opens
Settings; reopening an already-running app also brings Settings forward.

The default build uses the host architecture and outputs `dist/ReviewQ.app`. Quit the app before
rebuilding that output. You can copy it to Applications before enabling launch at login.

For development, `swift run ReviewQ` also works, but launch at login requires the app bundle.

Build one explicit architecture, or create both versioned ZIPs and checksums:

```sh
sh scripts/build-app.sh arm64       # dist/arm64/ReviewQ.app
sh scripts/build-app.sh x86_64      # dist/x86_64/ReviewQ.app
sh scripts/build-app.sh --release   # both ZIPs and SHA256SUMS.txt in dist/
```

The packaging script verifies each executable's architecture and each app's code signature before
archiving. Its release version comes from `Support/Info.plist`. Full native test commands are:

```sh
swift test --arch arm64
swift test --arch x86_64             # on an Intel Mac
```

On Apple Silicon, Rosetta must already be available and the SwiftPM runner itself must run as
Intel. On the release-validation Mac, Apple's accurate Vision OCR backend fails under Rosetta.
The three OCR-backed layout tests therefore run in the native 70-test suite, while the other
67 tests, including native window/interaction tests, run in this explicit Intel/Rosetta profile:

```sh
arch -x86_64 "$(xcrun --find swift)" test --arch x86_64 \
  --skip 'DashboardLayoutTests/(testDashboardRemovesFooterActionsButKeepsQuitAndRefreshTime|testDashboardStillIdentifiesTheLastSuccessfulUpdateAfterAnError|testReviewStagesAreBesideDraftWithoutNumbersOrAnotherRow)'
```

No tests are removed or weakened. ReviewQ itself does not use Vision or CoreML; OCR is only
part of the layout test harness. Version 1 is not claimed to have been tested on physical Intel
hardware.

## Compatibility with PRBar

ReviewQ was originally developed as PRBar. Version 1 deliberately retains the internal bundle
identifier `dev.prbar.app`, Azure DevOps Keychain service `dev.prbar.app.azure-devops`, preference
keys, and `~/Library/Logs/PRBar` directory. This preserves existing configuration, saved PATs,
verbose-logging preferences, and diagnostic history without a migration.

These legacy internal names do not affect ReviewQ's displayed name or limit future integrations.
PRBar and ReviewQ are the same app identity, not apps to run side by side. If you move the app,
check its launch-at-login setting from the final installed location.

## Repository dropdowns

The menu-bar queue shows one collapsible dropdown per repository. Each header displays the
repository name, its organization/project, and the pending PR count. Click anywhere on the header
to expand or collapse its reviews, then click a PR to open it in your browser.

Repositories start collapsed. Multiple repositories can be expanded at once, and your choices
are retained while the app is running, including across refreshes and closing/reopening the
popover. Collapsing a repository does not change the pending count or review filters.

Reviews within each repository are sorted by **creation time, newest first**. PR numbers are
hidden from the rows. A small **First Review** or **Re-review** label appears beside Draft when
applicable, without adding another row. Quit sits immediately to the left of Refresh; Settings
is available from the header's gear icon. The redundant bottom action row has been removed.

**First Review** means no previous nonzero vote or regular review comment from you was found.
**Re-review** means your Azure DevOps history contains a previous vote or review comment,
including a soft-deleted comment whose author is still recorded. Other reviewers' feedback,
system notifications, and simply having multiple commits do not mark a PR as your re-review.
These labels describe recorded feedback, not whether you have ever opened the PR in a browser.
Older discussion comments without a type are supported when they retain your authorship and
feedback content or a deletion marker; untyped system-thread activity does not count as a review.
Vote history supports both direct voter IDs and per-thread identity references.

Review history is read only for pending PRs, with at most four history requests in flight at once.
If history cannot be read, the refresh fails visibly instead of guessing a First Review label.

## Connect Azure DevOps

1. Enter one **organization or project URL per line** in Settings:

   ```text
   https://dev.azure.com/your-organization/your-project
   https://dev.azure.com/another-organization/another-project
   ```

   An organization-only URL searches **all projects your account can access**. Prefer project
   URLs for large organizations to reduce refresh time and API requests. Legacy URLs such as
   `https://your-organization.visualstudio.com/DefaultCollection/your-project` also work.
   Repository URLs and Azure DevOps Server/on-premises URLs are not supported.

2. Choose an authentication method:

   **Azure CLI (recommended)**

   Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-macos), then sign in:

   ```sh
   az login --allow-no-subscriptions
   ```

   If your organization requires a specific tenant:

   ```sh
   az login --tenant YOUR_TENANT_ID --allow-no-subscriptions
   ```

   Enter that tenant ID or domain in Settings as well. ReviewQ requests short-lived tokens for the
   [Azure DevOps resource](https://learn.microsoft.com/azure/devops/cli/entra-tokens)
   (`499b84ac-1321-427f-aa17-267ca6975798`) and keeps them in memory only. It detects Homebrew's
   Apple silicon and Intel Azure CLI installations even when launched from Finder.

   **Personal access token**

   Create a short-lived [PAT](https://learn.microsoft.com/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate)
   with **Code (Read)**. Organization-wide project discovery also needs **Project and Team (Read)**;
   alternatively, enter explicit project URLs. The token must cover every configured organization.
   If your company disables PATs, use Azure CLI instead.

   Paste the token in the secure field. Leave it blank on later saves to retain the stored token.
   **Delete saved PAT** removes it from Keychain. Switching to Azure CLI does not automatically
   delete a previously saved PAT.

3. Choose **Save and Refresh**.

## What counts as "needs review"?

A PR is included when it is active, directly lists the authenticated Azure DevOps user as a
reviewer, and that user's vote is **No vote (0)**. Your own PRs and declined reviews are excluded.
Approved, approved-with-suggestions, rejected, and waiting-for-author votes are excluded.
Drafts are excluded unless **Include draft pull requests** is enabled. The newest requests appear
first within each repository.

Identity is resolved separately in each organization; an Entra object ID is not substituted for
the Azure DevOps reviewer ID. Results are paginated and duplicate PRs across overlapping sources
are counted once. Team/group-only reviewer assignments are not expanded in this initial version.

All configured sources must refresh successfully before the queue is replaced. If any source
fails, the last successful queue remains visible with an error banner, its original update time,
and a `!` in the menu bar. Before the first successful refresh, no zero count is shown.
Review data is kept in memory, not persisted to disk.

## Diagnostics

Open **Settings > Diagnostics...**, or right-click the header's Settings gear and choose
**Diagnostics...**. The window includes **Enable verbose logging**, **Show in Finder**,
**Clear Logs...**, and **Export Logs...**. In Settings, Command-Shift-D opens Diagnostics.
To open the Diagnostics window when launching a stopped app:

```sh
open dist/ReviewQ.app --args --diagnostics
```

This follows the AppFoundations diagnostics contract with a self-contained implementation.
Logs are local JSON Lines in the retained compatibility directory,
`~/Library/Logs/PRBar/warnings-errors.log` and `verbose.log`.

Warnings/errors and startup version/build/OS/architecture information are recorded by default.
Verbose logging is opt-in and adds authentication, refresh, and HTTP request starts/outcomes,
random session/refresh/request correlation IDs, HTTP status, monotonic duration, response byte
counts, and page numbers. Refresh-start `count` means configured source lines; refresh-finish
`count` means pending PRs; eviction `count`, when available, means discarded records.

Both files are owner-readable/writable only, capped at **5 MiB each / 10 MiB total**, with
**seven-day retention** maintained at startup, on writes, and before export. Malformed records
are discarded during maintenance. Disabling verbose logging stops future optional collection,
not deletion of already collected records. Clear removes old records and retains current
startup metadata. Storage and export failures remain visible in Diagnostics.

Exports include exactly the two log files and `diagnostic-summary.json` in a ZIP. Temporary
export files are removed on success and failure. Nothing is uploaded automatically. Credentials,
headers/bodies, PR titles/comments, identities, private URLs, and arbitrary error descriptions
are excluded even in verbose mode. Logs do contain usage timestamps; review exports before sharing.

## Security and permissions

Only read-only Azure DevOps requests are made. Clicking a PR opens its page in your browser; the
app does not submit votes, comments, or modify PRs. Requests are restricted to HTTPS Azure DevOps
Services endpoints and HTTP redirects are rejected. Tokens are never put in URLs, preferences,
or diagnostic logs. Azure CLI manages its own sign-in cache outside ReviewQ.

No Accessibility, Input Monitoring, or browser-cookie access is required. Launch at login uses
macOS Service Management and may require approval in System Settings.

## Tests

```sh
swift test
```

Tests use synthetic Azure DevOps responses and isolated preferences; they do not access your
account, real Keychain entries, or live Azure DevOps projects.

Native dropdown tests require a macOS GUI session and briefly show a sample window to validate
mouse clicks, expand/collapse, and refresh updates. Layout tests inspect native rendered images
with Vision OCR. They do not require Accessibility permission.
