# 2 — Both clients show and edit membership

Part of: .scratch/task-factory-integration/spec.md
Status: done — branch `issue/02-both-clients-show-and-edit-membership`
Labels: feature

## What to build

Both clients show where a session belongs, and both let James change it by hand.

The sidebar in the web app and the sidebar in the macOS app render membership from the session's
server-declared group, merged with the order James has set by hand — order stays his, membership
is the server's. Dragging a tile into or out of a group is a server write. A tile shows the group
it belongs to, and James can tell a server-declared group from one of his own, so he does not
fight the app over a tile's home.

A group keeps its members across a restart, and a new member does not reshuffle the rest.

## Acceptance criteria

- [ ] A session created in a group appears under that group in both clients
- [ ] Dragging a tile into a group and out of one persists across a reload and across a restart
- [ ] Adding a member leaves the order of the existing members alone
- [ ] A client that has never seen the groups adopts them instead of erasing them (the ADR-0006 property still holds)
- [ ] The tile shows the group it belongs to
- [ ] James can tell a server-declared group from one of his own
- [ ] The fixture gains a case for which tiles are in which group in which order, asserted by both suites
- [ ] The macOS app's sidebar agrees with the web app's about the same session list

## Blocked by

1 — the server owns a session's group and directory


## Status

Done on branch `issue/02-both-clients-show-and-edit-membership` (built, both suites green). The
membership merge lives in `web/public/session-order.js` and
`Sources/AgentHub/Services/SidebarOrder.swift`, asserted identically by both suites through
`contract/sidebar-membership.json`. The new server route is
`POST /api/sessions/{name}/group`; the contract is at version 9.
