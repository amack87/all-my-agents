// What a person can see about membership: the group on the tile, and which
// groups are the server's rather than James's (docs/adr/0017-sessions-declare-
// group-state-and-working-directory.md).
import { test } from "node:test";
import assert from "node:assert/strict";

import { groupOf, groupBadgeHtml, serverGroupTagHtml } from "../public/session-membership.js";

test("a tile that belongs to a group shows the group", () => {
  const html = groupBadgeHtml({ name: "alpha", group: "Task Factory" });
  assert.match(html, /session-group-badge/);
  assert.match(html, /Task Factory/);
});

test("a tile with no declared group shows nothing", () => {
  assert.equal(groupBadgeHtml({ name: "alpha", group: null }), "");
  assert.equal(groupBadgeHtml({ name: "alpha" }), "");
});

test("the badge escapes the group name", () => {
  const html = groupBadgeHtml({ name: "alpha", group: 'Work <b>&"x"' });
  assert.doesNotMatch(html, /<b>/);
  assert.match(html, /&lt;b&gt;/);
});

test("a server-declared group header is marked so James can tell it from his own", () => {
  const html = serverGroupTagHtml({ name: "Task Factory", serverDeclared: true });
  assert.match(html, /group-server-tag/);
  assert.match(html, /server/);
});

test("a group James claimed is not marked as the server's", () => {
  assert.equal(serverGroupTagHtml({ name: "Work", serverDeclared: false }), "");
  assert.equal(serverGroupTagHtml(null), "");
});

test("the declared group is read from the session, and nothing else passes as one", () => {
  assert.equal(groupOf({ name: "alpha", group: "Work" }), "Work");
  assert.equal(groupOf({ name: "alpha", group: "" }), null);
  assert.equal(groupOf({ name: "alpha", group: 42 }), null);
  assert.equal(groupOf(null), null);
});
