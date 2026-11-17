# PR Context: Release ReviewQ v3.1.1

## Summary

Release version 3.1.1 / build 8 fixes status-icon close/reopen flicker, limits the pending-review
count to assigned PRs, and refines dashboard actions and creator attribution. GitHub PR integration
remains out of scope; this release continues to support Azure DevOps only.

## Key Decisions

| Decision | Rationale | Alternatives considered | Impact and tradeoffs |
| --- | --- | --- | --- |
| Own popover dismissal and exclude status-icon events in screen coordinates. | A click-away close before the button action can turn a close into a reopen; windowless macOS mouse events use screen coordinates. | Transient popover behavior was insufficient; local-window-only filtering did not cover globally hosted status-icon events. | Click-away monitors exist only while the queue is open, are removed on close/termination, and do not consume outside clicks. |
| Dismiss on an active foreign application's activation rather than generic app deactivation. | Menu-bar interaction can temporarily resign activity before the icon action. | Immediate resign-active dismissal reproduced the close/reopen regression. | Own activation and stale inactive-app notifications are ignored; real app switching still dismisses the queue. |
| Compute the pending count from assigned, non-authored PRs. | Following an author must not increase the number of reviews assigned to the user. | The previous shared total included followed-only PRs. | Menu-bar, accessibility, and header counts agree; cached snapshots need no migration and optional reviewer assignments still count. |
| Keep Setup first in the header and put the creator link in the footer. | Implements the requested Setup, Refresh, Settings, Power ordering and exact attribution text. | Footer setup and a visible Quit word were superseded by the requested layout. | Fixed icon slots preserve alignment while refreshing; Setup still refuses to discard an open Settings editor. |

## Key Flows

### Opening and closing the queue

1. The status-icon action and Command-Option-Q release use the same current-popover-state toggle.
2. Opening activates ReviewQ, shows its application-defined popover, and installs local/global
   mouse-down monitors.
3. Mouse events over the icon are excluded from click-away handling, including windowless global
   events. The subsequent icon action therefore closes the already-open queue rather than reopening it.
4. Outside clicks, Escape, or activation of another active app close the queue and remove the monitors.
   Monitor-installation failure remains a visible action error.

### Counts and dashboard actions

1. A successful or cached snapshot computes pending reviews by excluding followed-only and authored PRs.
   Assigned/followed overlap remains deduplicated and counts once.
2. Header controls run Setup, Refresh, Settings, divider, Power. Refresh retains Command-R and Settings
   retains its Diagnostics context menu.
3. The footer's `By: Hritvik Patel` action opens the GitHub profile in the default browser. A failed
   open reports the existing visible browser error; success closes the popover.

## FAQs

### What remains unchanged?

Azure DevOps discovery, authentication, saved settings and PATs, bundle identity `dev.prbar.app`,
refresh intervals, cached-startup behavior, and changes-since-refresh dots are unchanged.
There are no new dependencies, network requests, timers, or permission requirements.

### How was this validated?

The strengthened status-icon regression failed against the earlier close/reopen sequence, then passed
after the fix. The full release profile passed 235 tests on Apple Silicon and 235 on Intel/Rosetta,
with the same five documented host-dependent OCR exclusions. It includes the 17 focused native
window/shortcut tests for repeated mixed input, click-away delivery, Escape, own/stale/foreign app
activation, creator-link success/failure, safe Quit invocation, and toolbar actions in both appearances.

Both packaged apps and extracted ZIP payloads passed strict/deep code-signature checks. Checksums,
architecture, version 3.1.1/build 8, minimum macOS 14, bundle identity, icon resource, and compiled-binary
UUIDs were also verified. Temporary extracted payloads were removed.

Live desktop click verification was unavailable because the Computer Use host lacked Accessibility
and Screen Recording permissions. Native in-process events and synthetic Azure DevOps data are used;
no physical Intel, live-service, or latency-benchmark validation is claimed.

### How can this be rolled back?

Quit ReviewQ and restore the previous v3.1.0 application bundle. The internal identity, preferences,
Keychain service, and cache schema are unchanged, so no migration reversal is required.
Downloads remain ad-hoc signed rather than Developer ID signed or notarized.
