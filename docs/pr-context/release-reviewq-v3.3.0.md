# PR Context: Release ReviewQ v3.3.0

## Summary

Version 3.3.0 / build 10 adds local, reversible PR archiving across assigned, followed, and authored
queues. Archived PRs move to a bottom Archives section and stop contributing to active lists,
counts, and refresh-change indicators. This release also aligns the Archive/Restore icons with
existing actions and gives authored cards an explicit Microsoft Edge shortcut.

## Key Decisions

| Decision | Rationale | Alternatives considered | Impact and tradeoffs |
| --- | --- | --- | --- |
| Archive locally without modifying Azure DevOps or adding requests. | The requested behavior is hiding PRs from active lists while retaining a way to restore them. | Remote PR mutation is outside this scope. | Archive/Restore needs no new permission and does not vote, abandon, or complete a PR. |
| Save only canonical IDs under the existing authenticated/source scope. | Choices must survive restarts without moving between accounts or repositories with similar display names. | A separate historical PR database was not needed for this scope. | Source/following-scope changes select separate choices. Absent PRs are not displayed, but retain their archive choice if they return. |
| Keep raw snapshots and queue-cache data unchanged; filter store projections and both refresh baselines. | Restoration and authenticated cached startup need the original PR data, and local hiding must not fabricate server changes. | Filtering the loader/cache would lose archived metadata and distort comparisons. | Archived-only changes do not light active sections. Restoring can reveal a real change from the last successful refresh. |
| Reuse existing card layout, icon affordances, and Edge launcher. | The user requested matching white-backed colored icons and an Edge shortcut in the authored section. | A misleading Edge graphic on a default-browser action was avoided. | Card clicks still use the default browser; the Edge icon opens Edge explicitly. Archived cards keep their generic browser action. |
| Bound and validate local archive storage before publishing changes. | Corrupt or full preferences must not silently hide PRs or appear successful. | Additional persistence dependencies were unnecessary. | The archive is limited to 4,096 saved IDs across scopes and 512 KiB. Errors are visible and safely categorized in Diagnostics. |

## Key Flows

### Archive, refresh, and restore

1. A card's Archive action checks that the PR still belongs to the authenticated snapshot and
   validates its canonical ID and scope.
2. The store encodes and bounds the updated choices, persists them, then publishes active/archive
   projections and recomputes changes against the same preceding network snapshot.
3. Repository, followed, and authored queues omit the PR; assigned-review counts and status-item
   tooltip/accessibility text use the active subset.
4. The collapsed Archives section remains reachable even when every PR is archived. It displays
   current snapshot metadata, newest first, with repository context and browser/Restore actions.
5. A network refresh still loads and caches the full queue. Missing PRs disappear from Archives
   without deleting their saved choices. Restore reverses the local filter without a request.
6. Invalid stored choices are cleared with an explicit error. Stale/unscoped actions or full storage
   leave the active state unchanged and report an `archives` diagnostic without PR details.

### Authored Edge shortcut

1. The authored section supplies both the default-browser card action and the existing Edge action.
2. Authored cards show Archive and Edge, never Scout or Copilot; Edge remains usable during an
   unrelated AI launch.
3. Missing Edge or an open failure uses the existing visible launcher error. The card remains a
   separate default-browser link. Archive/Restore actions do not fall through to either browser.

## FAQs

### Is this a historical archive or an Azure DevOps operation?

Neither. Only archived PRs still returned by the configured sources and filters are displayed.
Saved choices contain no copied PR titles, authors, URLs, credentials, or historical snapshots.
Archiving does not make an Azure DevOps request.

### What remains unchanged?

Azure DevOps is still the only PR provider. Existing settings, Keychain service, bundle identifier
`dev.prbar.app`, raw queue cache, update-check cadence, menu toggling, and assistant launch behavior
are preserved. Counts still exclude followed-only and authored PRs. Green dots continue to mean
changes since the previous successful network refresh, not unread state.

### How was this validated?

Before release preparation, 131 affected-path tests passed on each architecture. Subsequent icon
changes passed 11 tests per architecture, and the authored Edge change passed 15 per architecture.
Coverage includes scoped persistence, cached relaunch, failures/disappearance/reappearance,
capacity-error recovery, active count/tooltip updates, refresh-baseline behavior, native
Archive/Restore/browser clicks for all queue kinds in light/dark, and authored Edge dispatch without
default-browser or assistant fallthrough. Native previews were inspected in both appearances.

The full release profile ran 259 tests per architecture with the same five existing OCR exclusions.
On each architecture, 256 passed and these three unchanged tests failed with four assertions:

- `NativeEditMenuTests/testMultilineEditorSelectsCopiesAndPastesExactText`
- `NativeEditMenuTests/testSingleLineFieldEditorSelectsCopiesAndPastesExactText`
- `DashboardLayoutTests/testPeopleSectionIsBelowAllRepositoryHeaders`

The same failures reproduced on an isolated, untouched v3.2.0 worktree on Apple Silicon and
Intel/Rosetta. They remain reported failures, not new exclusions. All nine new archive tests,
the authored Edge regressions, and all ten native window tests passed on both architectures.
The native-window harness now prefers the available higher-resolution display: its fast OCR
misread small glyphs when the host's default display changed to 1x. No behavioral assertions were
removed or weakened, and the unrelated baseline clipboard/OCR tests were not changed.

Both packaged apps and extracted ZIP payloads passed strict/deep signature, architecture,
version 3.3.0/build 10, minimum macOS 14 (plist and executable), bundle-identity, icon-resource,
compiled-UUID, and SHA-256 checks. The running default bundle was not replaced or relaunched.
Intel validation used Rosetta, not physical Intel hardware; no live Azure DevOps or external
desktop-automation validation is claimed.

### How can this be diagnosed or rolled back?

Diagnostics uses the `archives` operation and `reviewArchived`, `reviewRestored`,
`archiveChangeFailed`, and `archiveStateInvalidated` events without PR titles, IDs, or URLs.
Quit ReviewQ and restore the v3.2.0 bundle to roll back. That version ignores the new local
`reviewArchivedPullRequests` preference, so previously archived PRs return to its active queues;
credentials and existing configuration need no migration reversal.

Downloads remain ad-hoc signed, not Developer ID signed or Apple-notarized. Do not disable
Gatekeeper or other macOS security protections.
