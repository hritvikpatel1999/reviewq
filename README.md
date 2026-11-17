# ReviewQ

*Your reviews. One queue.*

A standalone native macOS menu-bar app for Azure DevOps pull requests that need your review.
ReviewQ does not require SwiftBar, LeetBar, or AppFoundations at build time or runtime.
Version 3 supports **Azure DevOps only**. GitHub pull-request integration is planned for a
future version, not included in this release.

## Features

- Native pull-request icon counting only PRs assigned to you for review, excluding followed-only and authored PRs.
- Green dots on the menu-bar icon, affected sections, and PRs changed since the previous successful refresh.
- A bundled application icon for Finder, Spotlight, and app launchers.
- Newest-first repository dropdowns with pending counts, author, age, review-stage labels, and one-click browser links.
- Per-PR Edge, Scout, and Copilot actions with hover feedback.
- Separate Scout/Copilot review instructions, with a 1,000-character limit per app.
- Command-Option-Q to open or close the menu-bar queue from any app.
- First Review, You Approved, You Approved with Suggestions, You Waited for Author, You Rejected,
  and comment-resolution labels based on your recorded review history.
- Multiple Azure DevOps organizations and projects.
- An opt-in, collapsible **People you follow** queue for PRs by configured authors.
- An opt-in, collapsible **I'm the Author** section with active discussion counts, approval readiness, and browser-only links.
- Persistent, account-scoped user/author identity caches with a manual re-lookup control.
- Automatic refresh (1, 5, 15, or 30 minutes; 15 by default), manual refresh, and refresh after wake.
- Restore the last successful queue while a startup refresh loads fresh data for the same account.
- A dismissible new-release banner with **View Updates** and a manual update check in Settings.
- Microsoft Entra authentication through your existing Azure CLI sign-in.
- Optional personal access token stored only in macOS Keychain.
- Settings, optional draft PRs, and launch at login.
- A resumable six-screen first-run setup with connection testing and optional assistant setup.
- Native Select All, Copy, Paste, Cut, Undo, and Redo shortcuts in Settings.
- Visible authentication/network errors; failed refreshes never masquerade as an empty queue.
- Local diagnostics with opt-in verbose logging, correlated request outcomes, and private ZIP exports.

## App update notifications

ReviewQ checks its public GitHub latest-release metadata in the background when it launches, wakes,
or opens the queue, only if the previous successful check was at least 24 hours ago.
PR refreshes do not check for app updates. Checks are independent of Azure DevOps authentication and
PR loading, require no GitHub account or token, and add at most one concurrent update request.
No background service or update timer runs while the app is closed.

A newer stable version shows a blue-accented banner beneath the queue toolbar. **View Updates**
opens that release's GitHub page for manual download and installation; ReviewQ does not download,
replace, or relaunch itself. Quit the old instance before installing the replacement.
The **x** dismisses only that version, including across app restarts. A later release appears again.
After upgrading, the banner disappears automatically. Drafts, prereleases, and older/equal versions
are not offered; versions are compared numerically.

**Settings > App updates > Check for Updates** bypasses the daily interval, but still honors GitHub's
rate-limit and retry deadlines. Dismissed updates remain accessible there. Offline or invalid responses
preserve the cached release and last successful check, back off automatic retries, and log a safe
failure category in Diagnostics. A failed manual check shows an error rather than claiming the app
is up to date.

The local `reviewAppUpdates` preference stores only release metadata, ETag, check/retry times, and the
dismissed version; it contains no credentials or PR data. GitHub receives the normal public HTTPS
request, including your network's IP address, but no Azure DevOps credentials or queue contents.
Conditional requests reduce response size; anonymous requests still share GitHub's per-IP rate
limits. Update notifications do not alter the green changes-since-refresh dots or pending-review count.
Checks require a packaged app with a valid bundle version; `swift run` development builds may not
include that metadata.

## First-run setup

New installations open **ReviewQ Setup**: Welcome, review sources, Azure DevOps connection,
optional review companions, preferences, and a ready screen. The native window follows macOS
light/dark appearance and the same accent as Settings, with progress markers, status cards, and
fixed Back/Continue controls.
Existing configured installations continue straight to the menu bar without being re-onboarded.

- Enter one organization or project URL per line. Use a project URL for focused, faster discovery.
- Choose Azure CLI or a read-only PAT and select **Test connection**. Sign-in is performed by you
  in Terminal; setup does not install software or run `az login` automatically.
- Connection testing uses the existing read-only loader against your draft sources. A failed
  check cannot appear as an empty successful queue or unlock completion.
- Scout, VS Code, and Edge are optional. **Detected** means the app is installed, not that its
  account is signed in. Only Scout automation needs Accessibility permission, requested by an
  explicit button. ReviewQ does not need microphone or Screen Recording permission.
- VS Code keeps its profile's permission defaults. The optional Autopilot guide does not enable
  Allow All or change VS Code settings or organization policies.
- Refresh defaults to 15 minutes; following people, authored PRs, drafts, and launch at login
  remain opt-in. Extra queue choices are checked before reaching the ready screen.
- **Open my queue** saves settings, stores a new PAT in Keychain, and opens the verified queue.
  A fresh snapshot is reused rather than immediately repeating its network refresh; a result older
  than the selected refresh interval triggers a normal refresh. Normal polling, manual refresh,
  and green change indicators continue to work as before.

Closing setup pauses it. Draft preferences and the current step are stored locally under
`reviewOnboardingProgress`; PATs and fetched queues are **never** stored in that draft.
Reopening after a connection check returns to authentication to verify access again. An unsaved
PAT must be entered again. Completed setup is recorded under `reviewOnboardingCompleted`.
Launch-at-login changes are applied immediately, as in Settings, and remain independently
configurable through macOS.

To revisit setup, close Settings and click **Setup** in the menu-bar queue's header, before
Refresh and Settings. The button is also available before a queue has loaded. Setup refuses to
discard an open Settings editor. A replay starts from the latest saved preferences; **Keep existing
settings** abandons the replay without replacing them. Advanced assistant prompts, caches, and
logs remain in Settings/Diagnostics. Developers can also start the app with `--setup`.

## What's new in version 2

- Start a new Scout or VS Code Copilot agent chat with exactly `Review PR: {PR Link}` from each PR.
- Open explicitly in Microsoft Edge, or click the row to keep using your default browser.
- Enabled icons enlarge 15% and show a rounded highlight on hover, with Reduce Motion support.
- Replace First Review/Re-review with six precise previous-review states; later vote resets do
  not erase your prior feedback.
- Show PR age without the redundant "old" suffix.

Existing settings, saved PATs, launch-at-login identity, and diagnostics are preserved.
The [version 2.1 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v2.1.0),
[version 2 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v2.0.0) and
[version 1 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v1.0.0) remain available.

## What's new in version 2.1

Version **2.1.0 / build 3** adds:

- Separate **Scout** and **GitHub Copilot** additional instructions under **Settings > Review
  instructions**. The fixed first line is always `Review PR: {PR Link}`; instructions are appended
  after a blank line. Empty or whitespace-only instructions keep the version 2 default exactly.
- A **1,000-character limit per app**, counting Unicode characters rather than bytes, with live
  counters and visible validation. Over-limit input is not silently truncated and cannot be saved.
  Ordinary multiline text is supported; tabs and other non-line-break control characters are rejected.
  Surrounding whitespace is trimmed and line endings are normalized only when composing the prompt.
- **Command-Option-Q** to open or close the menu-bar queue, including while another app is active.
  It triggers once on release, not repeatedly while held. A conflicting shortcut is reported in
  Settings with **Retry shortcut** after freeing the combination in the other app.

For example, set Scout's additional instructions to `Use my review-pr skill. Focus on correctness.`
and Copilot's to `Use my review workflow. Focus on regressions.` Then choose **Save and Refresh**.
Each PR action uses only that assistant's latest saved instructions. Existing version 1/2 settings
and saved PATs remain intact; missing prompt settings default to empty.

Additional instructions are stored locally in preferences, **not encrypted in Keychain**.
Do not put secrets in them. ReviewQ hands the PR link and the selected instructions to the local
assistant; neither the instructions nor the composed prompt are included in diagnostics.
Scout inserts line breaks without submitting early and verifies the complete draft before Send.
The global shortcut needs no additional Accessibility or Input Monitoring permission.
Scout's cold-launch automation remains unreliable; open Scout manually before
trying its action. Launcher failures remain visible, and no blind typing or submission retry is used.

Version 2.1.0 validation passed **104 native tests** and **101 Intel/Rosetta tests**; the three existing
accurate Vision OCR layout checks remain native-only. Both actual Settings editors were tested
at 1,000/1,001 characters, including the Save button boundary, and the global shortcut was tested
against the running native popover from another app.

## What's new in version 2.2

Version **2.2.0 / build 4** adds comment-resolution labels and native Settings editing shortcuts.

### Comment-resolution labels

ReviewQ shows three comment-only labels using the existing PR thread response:

- **Your comments are resolved** when every current discussion containing a non-deleted comment
  from you is marked **Fixed**.
- **You commented [2 resolved, 1 open]** when all relevant statuses are known and some discussions
  remain **Active** or **Pending**. Counts are discussions, not individual replies; multiple replies
  from you in one thread count once.
- **You commented** when resolution totals cannot be stated reliably, including missing/unknown
  statuses, other closure reasons (**Won't Fix**, **By Design**, **Closed**), or only deleted feedback.

Deleted discussions and other reviewers' feedback do not affect the counts. Previous approval,
suggestions, wait-for-author, or rejection votes retain their existing precedence.
The count text stays on the existing metadata line and is included in accessibility labels and
hover explanations. Thread status is not proof that a requested code change was made.

There are **no additional HTTP calls, query parameters, authentication requests, or polling**.
Resolution is calculated once per normal refresh from fields already returned by Azure DevOps;
the UI does not refetch discussions when rendering or hovering.

An optimized comparison against published V2.1 used identical synthetic thread payloads and
alternated baseline/candidate execution over nine paired samples. The extra classification work
was approximately **0.0025 ms for 20 threads**, **0.027 ms for 200**, and **0.145 ms for 1,000**.
Including JSON decoding, the 200-thread string-status workload added about **0.15 ms** to a
roughly 46 ms baseline; other decoding differences were within timing noise, not evidence of a
speedup. Each queued PR retains **24 additional bytes** for counts; the decoded thread stride
remains unchanged, and no extra comment content is retained. These are local CPU measurements,
not real-server latency or end-to-end UI benchmarks.

### Settings keyboard shortcuts

ReviewQ installs native Edit commands so **Command-A**, **Command-C**, and **Command-V**
work in Settings text fields and multiline editors. Standard Cut, Undo, and Redo shortcuts are
also available. Commands follow the focused control's native responder chain; secure PAT fields
keep macOS restrictions on copying secrets. **Command-Option-Q** still toggles the menu-bar queue.

Version 2.2.0 release validation passed **122 native tests** and **119 Intel/Rosetta tests**.
The three accurate Vision OCR checks remain native-only. Editing tests cover single-line and
multiline inputs, secure-field copy restrictions, and Undo/Redo. Native Command-A was also
verified in all four actual Settings inputs, and the global shortcut opened and closed the live queue.

## What's new in version 2.3

Version **2.3.0 / build 5** adds:

- A real application icon in every packaged build, replacing the generic placeholder in Finder,
  Spotlight, and app launchers. Rebuilt bundles refresh their timestamp to invalidate stale icons.
  The menu-bar symbol and background-app behavior are unchanged.
- Opt-in author following with semicolon-separated emails and a separate, collapsible
  **People you follow** section below repositories. Followed cards show **`{author} in {repo-name}`**;
  cards, actions, ordering, and deduplication match the existing queue.
- Persistent current-user and followed-author identity caches: **7 days** for resolved IDs and
  **15 minutes** for definitive author no-matches. Caches are scoped to the authenticated
  account/tenant and configured sources/people. PRs, votes, and discussion states remain fresh.
- **Settings > Identity cache > Refresh identities** to clear identities and renew authentication
  using saved settings without saving or discarding a Settings draft.
- A **15-minute default** for new configurations. Existing saved intervals are preserved.
- Atomic executable replacement during packaging, avoiding stale code-signing pages when rebuilding
  a previously launched app.

Existing preferences, Keychain PATs, diagnostics, assistant instructions, and shortcuts are preserved.
The [version 2.2 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v2.2.0) remains available.

Release validation passed **173 Apple Silicon tests** and **173 Intel/Rosetta tests**, including
icon decoding/bundle lookup, following, cache expiry/account isolation, and native interaction tests.
Five host-dependent OCR checks were excluded as documented below. Both ZIPs passed signature,
architecture, version/build, minimum-OS, checksum, and native macOS icon-resolution checks.

## What's new in version 3

Version **3.0.0 / build 6** adds:

- An opt-in, collapsible **I'm the Author** section below the review queues. Enable
  **Show PRs I've authored** in Settings and choose **Save and Refresh** to list your active PRs
  across accessible projects in configured organizations, newest first.
- **`{X} Active Comments`** for nonzero unresolved discussion-thread counts, including pending
  discussions, and **Merge Ready** for non-draft PRs with required approvals and no active comments.
  Builds and other completion requirements are deliberately not checked.
- Browser-only authored cards with `{author} in {repo-name}` labels. Authored PRs are deduplicated
  from other queues and do not increase the pending-review count.
- Fresh reviewer-policy evaluation with bounded enrichment and shared identity/project discovery.
  Disabled installations make no authored-queue requests; existing saved preferences stay intact.
- A fix for Azure DevOps returning URL-encoded policy artifact identifiers. Identifiers are decoded
  once before correlation; malformed identifiers and policies for another PR are still rejected.

The app remains read-only toward Azure DevOps. Copilot Terminal integration, automatic chat reuse,
merge buttons, and comment-writing actions are not included. The
[version 2.3 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v2.3.0) remains available.

Release validation passed **199 Apple Silicon tests** and **199 Intel/Rosetta tests**, including
authored-query pagination, discussion/approval readiness, encoded policy correlation, diagnostic
privacy, section placement/collapse, settings, and browser-only interactions. The same five
host-dependent OCR checks remain excluded. Both ZIP payloads passed signature, architecture,
version/build, macOS minimum, icon-resource, build-identity, and checksum checks.

## What's new in version 3.1

Version **3.1.0 / build 7** adds:

- A resumable six-screen first-run experience with connection testing, optional companions,
  native blue accents, and a **Run Setup** button beside the queue's update time.
- Green change indicators on the menu-bar icon, affected repository/section headers, and changed PRs.
  Opening a PR does not clear its dot; the next successful refresh replaces the change indicators.
- A bounded local cache of the last successful queue. Once the existing authentication step matches
  the account and queue settings, the cached repositories and update time appear while fresh PRs
  load. The header's refresh spinner stays visible; failures keep the last successful data and show
  an explicit error. No extra authentication or Azure DevOps requests are added.

Release validation passed **233 tests on Apple Silicon and 233 on Intel/Rosetta**, with the same five
host-dependent OCR checks excluded. All new cache, setup, and change-indicator tests were included,
as were the native Settings editing tests. Cache coverage includes relaunch while loading, account
and preference isolation, successful empty queues, failure/cancellation preservation, size and age
limits, and the cached dashboard's update time and refresh indicator.
Both ZIP payloads passed strict signature, architecture, version/build, macOS minimum,
icon-resource, compiled-binary UUID, and checksum checks.

The [version 3.0 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.0.0) remains available.
Read the [cached startup details](#cached-startup-queue) before relying on an older displayed status.

## What's new in version 3.1.1

Version **3.1.1 / build 8** fixes queue toggling and refines the dashboard:

- Prevent a status-icon click from closing the queue on mouse-down and reopening it on mouse-up.
  Click-away handling excludes the icon even for windowless macOS events; actual app switches,
  outside clicks, Escape, and Command-Option-Q continue to dismiss or toggle the queue.
- Count only PRs assigned to you for review in the menu bar and pending-review header.
  Followed-only and authored PRs remain visible in their enabled sections without inflating that count.
- Place header actions in this order: **Setup, Refresh, Settings, Power (Quit)**.
  The footer keeps the update time on the left and a **By: Hritvik Patel** GitHub link on the right.

The fixes add no network requests, polling timers, dependencies, or permission requirements.
Existing settings, cached queues, Keychain credentials, and refresh-change dot semantics are unchanged.
Native interaction regressions cover repeated icon/shortcut toggles, windowless status clicks,
click-away, Escape, app activation, and light/dark/cached-loading toolbar actions.

Release validation passed **235 tests on Apple Silicon and 235 on Intel/Rosetta**, with the same five
documented host-dependent OCR exclusions. Both extracted ZIP payloads passed checksum, strict/deep
signature, architecture, version/build, macOS minimum, bundle-identity, icon, and compiled-UUID checks.
Live desktop click verification was unavailable; testing used in-process native events and synthetic
Azure DevOps data rather than physical Intel hardware or live-service benchmarks.

The [version 3.1.0 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.1.0) remains available.

## What's new in version 3.2

Version **3.2.0 / build 9** adds app update notifications:

- A compact, dismissible banner beneath the queue toolbar with **View Updates**, opening the
  official release page for manual download and installation.
- Cached daily release checks when ReviewQ launches, wakes, or opens its queue. PR refreshes remain
  independent; no GitHub sign-in, extra dependency, background service, or new permission is required.
- **Settings > App updates > Check for Updates**, including access to dismissed releases and visible
  failures. Manual checks bypass the daily interval but honor GitHub retry/rate-limit deadlines.
- Numeric stable-version comparison, conditional ETag requests, per-version dismissal across
  restarts, and cached release information retained during failures.

ReviewQ does not automatically download, install, replace, or relaunch itself.
Existing Azure DevOps settings, saved credentials, queue caches, menu toggling, pending-review counts,
and green changes-since-refresh dots are unchanged. GitHub PR integration remains out of scope.
See [App update notifications](#app-update-notifications) for cadence, privacy, and failure handling.

Release validation ran **250 tests per architecture** with the same five documented OCR exclusions.
**248 passed on Apple Silicon and 248 on Intel/Rosetta**; two unchanged native clipboard tests
failed with three assertions, and the same failures reproduced on the unchanged v3.1.1 baseline.
All 15 new update tests and the expanded lifecycle/shortcut regression passed on both architectures.
No tests were removed, weakened, or newly excluded. Both ZIP payloads passed signature, architecture,
version/build, macOS minimum, icon-resource, compiled-UUID, and checksum verification.

The [version 3.1.1 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.1.1) remains available.

## Download version 3.2

Download from the [ReviewQ v3.2.0 release](https://github.com/hritvikpatel1999/reviewq/releases/tag/v3.2.0).
The repository and release downloads are public; no GitHub sign-in is required.

Requires **macOS 14 or later**:

- **Apple Silicon** (M-series Macs): `ReviewQ-3.2.0-macos-arm64.zip`.
- **Intel** Macs: `ReviewQ-3.2.0-macos-x86_64.zip`.
- `SHA256SUMS.txt` contains SHA-256 checksums for both ZIPs.

If you download both ZIPs and the checksum file into the same folder, verify them with:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

Extract the matching ZIP and move `ReviewQ.app` into Applications. Quit any previous PRBar or
ReviewQ instance before opening it. The app has no Dock icon; use its pull-request menu-bar icon.
Configure Azure DevOps as described below. Azure CLI is installed separately if you choose that
authentication method; a PAT does not require Azure CLI.

**Signing limitation:** version 3.2 builds are ad-hoc signed for integrity, not Developer ID signed
or Apple-notarized. macOS may warn about or block downloaded copies. Do not disable Gatekeeper or
other macOS security protections. Only use macOS's per-app approval if you have verified the
download and trust it; otherwise build locally or wait for a Developer ID signed/notarized release.
Checksums verify that your download matches the release asset, not Apple's approval of its publisher.
Intel builds are exercised under Rosetta on Apple Silicon, not on physical Intel hardware.

## Contributing

Changes to `main` must go through a pull request.
[CODEOWNERS](.github/CODEOWNERS) assigns every path, including the ownership file itself, to
[@hritvikpatel1999](https://github.com/hritvikpatel1999). For other contributors, the
[active ruleset](https://github.com/hritvikpatel1999/reviewq/rules/26963593) requires their
approving review before merging; new commits dismiss previous approvals.

The owner can explicitly bypass review requirements while merging a pull request, including their
own: GitHub does not allow authors to approve their own pull requests. This is a **pull-request-only**
bypass, not permission to push directly, force-push, or delete `main`. Those operations remain blocked.

GitHub implements the exception through its repository Admin role. In this personal repository,
that role belongs only to the owner, `hritvikpatel1999`; recheck the bypass before changing ownership
or administrator access. The ownership file alone does not enforce these requirements, so the
ruleset for `main` must remain active.

## Build and open

Requires **macOS 14+** and **Xcode 26+** (Swift 6.2 or later). Actor-isolated native shortcut
cleanup uses Swift 6.2; the macOS deployment minimum is unchanged. There are no third-party
package dependencies.

```sh
git clone https://github.com/hritvikpatel1999/reviewq.git
cd reviewq
swift test
sh scripts/build-app.sh
open dist/ReviewQ.app
```

The app has no Dock icon. Click its pull-request icon in the menu bar, or press Command-Option-Q,
to toggle the queue: either input closes an open queue and opens a closed one. Clicking outside,
switching apps, or pressing Escape also closes it. First launch opens setup; configured
installations skip it. Reopening an already-running app brings Settings forward, or resumes
unfinished setup. The subtle **By: Hritvik Patel** link at the footer's bottom-right, beside the
update time, opens [the creator's GitHub profile](https://github.com/hritvikpatel1999) in your default browser.

Menu-bar clicks are excluded from click-away handling even when macOS reports them without an app
window. Temporary menu-bar deactivation does not close the queue before the button's toggle.

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
archiving. It includes the checked-in `Support/AppIcon.icns` resource in every architecture.
To regenerate that original vector-based icon, run `swift scripts/generate-app-icon.swift`;
normal builds do not need to regenerate it. The release version comes from `Support/Info.plist`.
Full native test commands are:

```sh
swift test --arch arm64
swift test --arch x86_64             # on an Intel Mac
```

On Apple Silicon, Rosetta must already be available and the SwiftPM runner itself must run as
Intel. On this release-validation Mac, three accurate Vision OCR layout checks can stall or
fail under Rosetta, and two existing small-caption OCR checks misrecognize native bitmap text.
The tests remain unchanged; this host's release profile explicitly excludes those five OCR checks.
Core validation, icon checks, following/caching, review-history states, launchers, hover rendering,
and native window/interaction tests remain included:

```sh
swift test --arch arm64 \
  --skip '(DashboardLayoutTests/(testDashboardRemovesFooterActionsButKeepsQuitAndRefreshTime|testDashboardStillIdentifiesTheLastSuccessfulUpdateAfterAnError|testReviewStagesAreBesideDraftWithoutNumbersOrAnotherRow)|SettingsPromptTests/(testFollowSettingsShowsTheSemicolonExampleAndOptInExplanation|testInvalidFollowEmailsShowAnExplicitValidationErrorWhenEnabled))'

arch -x86_64 "$(xcrun --find swift)" test --arch x86_64 \
  --skip '(DashboardLayoutTests/(testDashboardRemovesFooterActionsButKeepsQuitAndRefreshTime|testDashboardStillIdentifiesTheLastSuccessfulUpdateAfterAnError|testReviewStagesAreBesideDraftWithoutNumbersOrAnotherRow)|SettingsPromptTests/(testFollowSettingsShowsTheSemicolonExampleAndOptInExplanation|testInvalidFollowEmailsShowAnExplicitValidationErrorWhenEnabled))'
```

No tests are removed or weakened. ReviewQ itself does not use Vision or CoreML; OCR is only
part of the layout test harness. ReviewQ is not claimed to have been tested on physical Intel
hardware.

## Compatibility with PRBar

ReviewQ was originally developed as PRBar. ReviewQ deliberately retains the internal bundle
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

## Review with Scout or Copilot

These actions are included in version 2; the v1.0.0 downloads do not include them.
Each PR now has three small icon buttons: Microsoft Edge, Scout, and Copilot. Hovering an enabled
icon enlarges it by 15% and shows a rounded highlight without moving the row or adding height.
Hover animation respects Reduce Motion. The Edge shortcut opens explicitly in Edge; clicking
the rest of the row still uses your default browser. Edge must be installed for its shortcut.
The AI buttons start a fresh chat with
`Review PR: {PR Link}` and submit it (plus any per-app instructions configured in version 2.1);
they do not automatically post a review or change
your Azure DevOps vote. The selected assistant's own permissions and review workflow still apply.

- **Scout:** requires Microsoft Scout installed and signed in. Allow ReviewQ in **System Settings
  > Privacy & Security > Accessibility** on the first attempt, then click Scout again.
  ReviewQ presses New chat, verifies an empty composer, types only into that confirmed focused
  control using events targeted to Scout's process, and presses Send.
  Submission is confirmed by the cleared draft and a new user message or running turn.
  Updating an ad-hoc signed build may require reapproving ReviewQ's Accessibility access.
- **Copilot:** requires a current Visual Studio Code supporting `code chat`, with Copilot enabled
  and signed in. ReviewQ uses VS Code's bundled CLI to open a **new empty window** in agent mode
  with the prompt already submitted. It does not reuse or replace your current VS Code chat.

### Scout still asks for Accessibility after an update

An enabled ReviewQ entry can refer to an older ad-hoc signing identity. These builds are
approved by their code hash, not by the displayed app name alone. Keep one installed copy
for normal use, and authorize the exact copy you launch, not an architecture-packaging copy
or the legacy PRBar app.

1. Quit ReviewQ after saving any Settings changes.
2. In **System Settings > Privacy & Security > Accessibility**, remove the old ReviewQ entry.
3. Use **+** to add your current `ReviewQ.app`, enable it, and confirm any macOS approval.
4. Reopen ReviewQ, open Scout manually, and try its review action again.

If the stale entry cannot be refreshed, reset **only ReviewQ's** Accessibility entry with
`tccutil reset Accessibility dev.prbar.app`, then add and approve the current app again.
This does not clear saved ReviewQ settings or Keychain PATs, but the Accessibility grant
must be confirmed again. Do not reset other apps' permissions or disable macOS protections.
A future Developer ID signed release can provide a stable signing identity across updates.

No clipboard replacement, tokens, PR titles, or PR content are sent by ReviewQ. Only the selected
PR link and any configured additional instructions are handed to the local app; that assistant
may fetch the PR through its own configured
tools. Launch diagnostics contain only the assistant, outcome, timing, and safe failure reason,
never the PR link or prompt. Missing apps, permissions, dialogs, changed drafts/focus, and
unconfirmed submissions are surfaced explicitly. Scout UI changes may require adapting its
Accessibility integration; ReviewQ does not fall back to blind keystrokes or retry a Send click.
The AI buttons are temporarily disabled while a launch is in progress to avoid duplicate chats.

Reviews within each repository are sorted by **creation time, newest first**. PR numbers and
the redundant "old" age suffix are hidden from the rows. A small previous-review status appears
beside Draft when applicable, without adding another row. Header actions run left to right:
Setup, Refresh, Settings (gear), then Quit (power icon), separated from Settings by a divider.
The footer keeps the update time on the left and the creator's GitHub link on the right.

The queue still includes only assigned active PRs that currently need your vote. Statuses describe
your **last recorded nonzero vote**, or your comment history when no nonzero vote was found,
not a current approval that no longer needs review:

- **First Review:** no previous nonzero vote or regular review comment from you was found.
- **You Approved:** your last nonzero vote was Approved (`10`).
- **You Approved with Suggestions:** your last nonzero vote was Approved with suggestions (`5`).
- **You Waited for Author:** your last nonzero vote was Waiting for author (`-5`).
- **You Rejected:** your last nonzero vote was Rejected (`-10`).
- **Your comments are resolved:** every current discussion containing a non-deleted comment
  from you is marked Fixed.
- **You commented [2 resolved, 1 open]:** all relevant discussion statuses are known and at least
  one discussion remains Active or Pending.
- **You commented:** review comments, including recorded soft-deleted comments, were found
  but no nonzero vote was found and resolution totals cannot be stated reliably.

Vote resets (`0`) do not erase your prior feedback. Publication timestamps determine the latest
vote, with thread IDs breaking same-time ties; comment edits and API response order do not
change the result. Missing/ambiguous chronology or unsupported vote values fail visibly rather
than guessing. Other reviewers' feedback, system activity, and simply opening a PR do not count
as your review. Comments after a vote do not replace the more informative vote status.
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

New configurations refresh **every 15 minutes** by default. Existing saved intervals, including
five minutes, are preserved; change **Settings > Preferences > Refresh** to choose another interval.

## Identity cache

ReviewQ persists only the identity metadata needed to avoid repeated account lookups:

- Your Azure DevOps user ID in each organization: **7 days**.
- Each followed email's Azure DevOps author ID, per organization: **7 days**.
- A complete, successful author lookup with no match: **15 minutes**.

Failures, ambiguous identities, malformed responses, and incomplete identity pages are never cached
as no-match results. A cached no-match still produces the normal unresolved-author error if the email
does not match in any configured organization. Hits do not extend expiry.

The bounded cache is separate from saved settings and survives app restarts. It is isolated by
authentication method, authenticated account/tenant, and configured sources/followed people.
Changing those inputs starts a fresh identity context. Azure CLI token renewal keeps the cache
when the token provides stable tenant/object claims; these claims partition the cache only, never
replace Azure DevOps identity lookups or authorize requests. Opaque credentials use a one-way
credential fingerprint, so their rotation conservatively starts a fresh context. Raw tokens and
authorization headers are never persisted in the cache.

Use **Settings > Identity cache > Refresh identities** after switching Azure CLI accounts, an account
recreation, or an email reassignment. This clears both identity caches, renews authentication, and
refreshes using **saved settings**, without saving or discarding a Settings draft. An ordinary
Refresh reuses unexpired identities. The last successful queue remains visible if re-lookup fails.

**PR lists, project discovery, reviewer votes, and comment/thread states still refresh normally.**
PR contents and history are not persisted. Identity cache diagnostics contain only event/reason
categories, not email addresses, organizations, user IDs, credential fingerprints, or token claims.

## People you follow

Following PR authors is **off by default**. In Settings, enable **Follow PR authors** and enter
email addresses separated by semicolons, **without spaces**:

```text
alex@example.com;sam@example.com
```

Choose **Save and Refresh**. A separate collapsible **People you follow** section appears **below all
repository dropdowns**. It starts collapsed; click its header to show or hide the PRs. The count stays
visible, and its expanded/collapsed state is retained through refreshes and reopening the menu.
It includes other active PRs created by these people, even when you are not a reviewer.
PRs already shown in a repository section are not duplicated. The cards, browser/assistant actions,
review-history labels, and newest-first sorting are unchanged; followed cards show
**`{author} in {repo-name}`** instead of just the author. No organization name is added to that line.
Followed-only PRs do not increase the menu-bar or header's pending-review count. A followed author's
PR that also needs your review appears in its repository section and counts once.

Following searches **all accessible projects in each configured organization**, even when a review
source is a project-specific URL. It never searches an unconfigured organization. The draft preference
also applies to followed PRs; completed and abandoned PRs are excluded. Unlike the assigned queue,
followed PRs are not restricted to your current reviewer vote.

**Permissions:** PATs need **Identity (Read)** to resolve author emails and **Project and Team (Read)**
to discover projects, in addition to **Code (Read)**. Azure CLI uses your existing account's access.
An email must resolve to an Azure DevOps user in at least one configured organization.
Unmatched or ambiguous identities, missing permissions, and failed requests are reported rather than
silently showing incomplete results. The last successful queue remains visible if a refresh fails.

**Requests and privacy:** with following off, there are no followed-author requests. With it on,
an identity cache miss adds one lookup per unique email per organization. Each refresh still adds
project discovery where it was not already needed, paginated creator-filtered PR queries per unique
author/project, and one history request per additional PR. Duplicate PRs do not get another history request. History loading
retains its four-request concurrency limit. Large organizations or long follow lists therefore take
longer to refresh. Emails are stored in local preferences and sent only to Azure DevOps for lookup;
they, identity responses, and query URLs are not written to diagnostic logs.

Turning the feature off removes the extra section on Save and Refresh and stops its requests.
Your email list is retained locally so you can enable it again.

## I'm the Author

In Settings, enable **Show PRs I've authored**, then choose **Save and Refresh**. This is **off by
default**, including for existing installations. A separate **I'm the Author** section appears below
the other queues. It starts collapsed, retains its expansion through refreshes/reopening, and lists
your active PRs newest first across accessible projects in configured organizations. The existing
draft preference applies; completed and abandoned PRs are excluded.

- **`{X} Active Comments`** appears only for a nonzero count. It counts active or pending unresolved
  discussion threads, not individual replies, system events, or deleted discussions/comments.
- **Merge Ready** appears only on non-draft PRs with no active comments, approved required reviewers,
  and satisfied blocking minimum-reviewer/required-reviewer policies. Azure DevOps evaluates those
  policies, including vote-reset and author-vote rules. Disabled, optional, and non-applicable policies
  do not block this label. With no approval requirements, no approvals are needed.
- **Build status is not checked.** Other completion requirements such as conflicts, work-item links,
  and external status checks are not part of this label either; it is not a guarantee of mergeability.
- Cards show the repository beside the author and have **only a browser button**. Clicking the card
  also opens the PR. No merge, Edge, Scout, or Copilot actions are added to this section.

Authored PRs are not duplicated in the other queues and do not increase the menu-bar or header's
pending-review count. The section has its own count. It adds no requests while disabled. When enabled,
it reuses your cached organization-specific user identity and per-refresh project discovery, queries
authored PRs by creator, and reads discussions plus paginated reviewer-policy evaluations per PR.
Enrichment retains the existing four-PR concurrency limit. PATs need **Code (Read)** and
**Project and Team (Read)**; no additional write scopes are required.

Counts and approval evaluations are recalculated on every successful refresh; the previous display
can be restored at startup as described below. Missing permissions,
incomplete responses, unknown discussion/reviewer-policy statuses, and network failures are reported
instead of producing a false Merge Ready label. As with other queues, a failed refresh preserves the
last successful snapshot with an error indicator. Turning the setting off and saving removes the
section and stops its extra requests.

## Changes since the previous refresh

Green dots identify differences between the latest two successful network refreshes, not unread
PRs. The menu-bar dot means at least one enabled queue changed; repository, **People you follow**,
and **I'm the Author** headers identify the affected sections, and PR cards identify new or updated
requests. Opening a PR or expanding a section does not clear a dot. Each successful refresh replaces
the indicators: an unchanged PR loses its dot on the next successful refresh, even if never opened.

The first successful load without a matching cache establishes a baseline without dots. Failed or
cancelled refreshes leave the last successful queue and dots intact. A restored queue and its compact
fingerprints provide the baseline for the next startup refresh; old dots themselves are not persisted.
Saving Settings or changing the authenticated account establishes a new baseline.

Detection uses the same PR, discussion, and authored reviewer-policy responses already fetched:
title/draft/review state, reviewer votes, source-commit markers when supplied by Azure DevOps, human
and system discussion updates (including replies, edits, deletions, and resolution), and authored
approval readiness. Refresh timestamps, relative age text, and response ordering do not create dots.
PRs leaving a queue mark its header and the menu bar, but no removed card or empty repository is
invented. Differences are observed at refresh time, not a complete log of events between refreshes.

There are **no additional HTTP calls, authentication requests, permissions, or polling timers**.
Build results, complete descriptions, and the precise reason a PR left a queue are not fetched for
this feature. A dot means changed, not necessarily actionable or approved; hover/accessibility text
explains its meaning.

## What counts as "needs review"?

In the repository sections, a PR is included when it is active, directly lists the authenticated Azure DevOps user as a
reviewer, and that user's vote is **No vote (0)**. Your own PRs and declined reviews are excluded.
Approved, approved-with-suggestions, rejected, and waiting-for-author votes are excluded.
Drafts are excluded unless **Include draft pull requests** is enabled. The newest requests appear
first within each repository.

Identity is resolved separately in each organization; an Entra object ID is not substituted for
the Azure DevOps reviewer ID. Results are paginated and duplicate PRs across overlapping sources
are counted once. Team/group-only reviewer assignments are not expanded in this version.

All configured sources must refresh successfully before the queue is replaced. If any source
fails, the last successful queue remains visible with an error banner, its original update time,
and a `!` in the menu bar. Before the first successful refresh, no zero count is shown.
Raw PR discussions and review-history responses are kept in memory, not persisted to disk.
The display-only startup cache below and the identity metadata described above are stored locally.

## Cached startup queue

After a successful refresh, ReviewQ stores one display snapshot under `reviewQueueCache` in local
preferences. It contains PR titles, author display names, repository/project names, browser links,
display flags and badges, the successful update time, compact change fingerprints, and hashed
account/settings scopes. It is **not encrypted**. PATs, access tokens, assistant prompts, descriptions,
and comment bodies are not included. The cache is not included in diagnostic log exports.

On relaunch, the normal credential acquisition runs first. Only a cache matching its account scope
and current queue settings is shown, before Azure DevOps PR requests begin. The original **Updated
... ago** time and the header's refreshing indicator distinguish the saved display from a fresh result.
A changed account, tenant, source, draft preference, or optional queue selection cannot reuse another
queue. An authentication failure before a matching scope is available does not expose cached data.

Successful empty queues are cached too. Failed, cancelled, and superseded refreshes do not replace
the cache. Only accepted, complete results are saved; setup saves its verified result on completion.
Saving Settings or deleting the active PAT clears the previous cache. Read-only display changes
such as the count, refresh interval, and assistant instructions do not affect the account/queue
fingerprint, although explicitly saving Settings still clears the old baseline.

Restoration is limited to snapshots less than **seven days** old, **2 MiB** encoded, and **4,096 PRs**.
Expired, future-dated, malformed, duplicate, or mismatched caches are discarded. Oversized queues
remain usable in memory but are not partially cached; a diagnostic warning explains why they will
need a fresh load next time. Warnings never include cached titles, URLs, or credentials.
Retention is checked when restoring, not by a background cleanup timer while the app is closed.
The first launch after upgrading must complete one successful refresh before a startup cache exists.

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
`count` means loaded PRs across all enabled queues; eviction `count`, when available, means discarded records.

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

Queue browsing and the Copilot launcher do not require Accessibility, Input Monitoring, or
browser-cookie access. The optional Scout launcher requires Accessibility permission for ReviewQ
to operate Scout's verified new-chat controls. The chosen assistant's own tools, permissions, and
review workflow apply after the prompt is submitted. Launch at login uses macOS Service Management
and may require approval in System Settings.

## Tests

```sh
swift test
```

Version 2.0.0 validation passed **86 native Apple Silicon tests** and **83 Intel/Rosetta tests**.
The three OCR-backed checks run natively, as documented in the Intel validation profile above.

Tests use synthetic Azure DevOps responses and isolated preferences; they do not access your
account, real Keychain entries, or live Azure DevOps projects.

Native dropdown tests require a macOS GUI session and briefly show a sample window to validate
mouse clicks, expand/collapse, and refresh updates. Layout tests inspect native rendered images
with Vision OCR. They do not require Accessibility permission.
