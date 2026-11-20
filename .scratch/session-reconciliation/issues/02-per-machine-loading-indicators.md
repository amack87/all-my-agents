# 2 — Per-machine loading indicators

Part of: .scratch/session-reconciliation/spec.md
Status: ready-for-agent
Labels: enhancement
Source: GitHub issue #3 (amack87/all-my-agents) — https://github.com/amack87/all-my-agents/issues/3
> **Migrated from [amack87/all-my-agents-web#3](https://github.com/amack87/all-my-agents-web/issues/3).**
> The web app now lives in `web/` in this monorepo, so file paths below are relative to the monorepo root.

## Parent

#1

## What to build

Add a subtle visual loading indicator to the peer status bar during session refresh. When a machine refresh is in progress, its badge in the peer status bar should show a gentle pulsing animation to indicate that data is being fetched.

**State:** A `refreshing: true` flag is set on each non-local machine entry before the mesh fetch starts. It's cleared per-machine when the response is processed — machines with `status: "ok"` or `status: "error"` both clear the flag; only machines that haven't responded yet remain `refreshing`.

**Rendering:** The peer status bar badges add a `.peer-indicator.refreshing` CSS class when a machine is refreshing. This class applies a subtle CSS animation (e.g., gentle opacity pulse) to give visual feedback without obtrusive spinners or session list disruption.

**Behavior:**
- Indicators appear only during the brief window between fetch start and response
- On fast responses (< 1s), the indicators may barely appear — this is correct (minimal visual noise)
- On slow responses (> 3s), the indicators reassure the user that refresh is in progress
- Machines that timed out show the existing error styling; machines that responded show OK styling

## Acceptance criteria

- [ ] Non-local machine badges show a subtle pulse animation while their refresh is in flight
- [ ] The `refreshing` flag clears per-machine as soon as its response data is processed
- [ ] Error and OK styling still work correctly alongside the refreshing animation
- [ ] No flicker — the animation is smooth CSS, not a class toggle race
- [ ] The session list itself is unaffected (no loading spinners, no session hiding)

## Blocked by

- #2
