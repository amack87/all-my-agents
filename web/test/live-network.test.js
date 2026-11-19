// The machine's own addresses must be recognised as they are NOW.
//
// Two decisions depend on which addresses this machine has: the origin
// allowlist (which origins may drive the API) and the trusted-source gate
// (which TCP connections may reach it). Both used to read the interfaces
// once, at boot. The machine's addresses change while the server runs —
// Tailscale connects, renumbers or reconnects, the Wi-Fi lease changes, the
// VM bridge appears when the VM is booted — and a snapshot taken at boot
// goes stale.
//
// The symptom was not a refusal anyone could read. A phone browsing the
// server by its Tailscale address was refused with a 403 on /app.js, so the
// page loaded, the script never arrived, and the app hung on "loading
// sessions". The same staleness refused the Windows VM's own traffic.
//
// The interface list is mocked here, so the tests can change it the way a
// network change does.

import { test } from "node:test";
import assert from "node:assert/strict";
import os from "node:os";

process.env.NODE_ENV = "test";
const { app, localAuthorities, isAllowedOrigin, isTrustedSocket } = await import("../server.js");

const PHONE = { address: "100.64.99.99", family: "IPv4", internal: false };
const PHONE_RENUMBERED = { address: "100.64.98.98", family: "IPv4", internal: false };
const BRIDGE = { address: "192.168.64.1", family: "IPv4", internal: false };
const LAN = { address: "192.168.1.178", family: "IPv4", internal: false };

test("the allowlist holds the addresses the machine has now", (t) => {
  t.mock.method(os, "networkInterfaces", () => ({ utun9: [PHONE] }));
  assert.ok(localAuthorities().has("100.64.99.99:3456"), "the phone's address is this machine's own");
  assert.equal(localAuthorities().has("100.64.98.98:3456"), false);
});

test("the allowlist follows the machine's addresses as they change", (t) => {
  t.mock.method(os, "networkInterfaces", () => ({ utun9: [PHONE] }));
  assert.ok(localAuthorities().has("100.64.99.99:3456"));
  // Tailscale renumbers: the old address is gone and a new one has arrived.
  t.mock.method(os, "networkInterfaces", () => ({ utun9: [PHONE_RENUMBERED] }));
  assert.ok(localAuthorities().has("100.64.98.98:3456"), "the new address is recognised");
  assert.equal(localAuthorities().has("100.64.99.99:3456"), false, "the old address is not");
});

test("a request from one of the machine's current addresses is served", async (t) => {
  t.mock.method(os, "networkInterfaces", () => ({ utun9: [PHONE] }));
  const server = app.listen(0);
  t.after(() => server.close());
  const port = server.address().port;

  // The path does not exist, so a request that gets past the origin gate
  // answers 404 — anything else means the gate refused it.
  const mine = await fetch(`http://127.0.0.1:${port}/api/nope`, {
    headers: { Origin: "http://100.64.99.99:3456" },
  });
  assert.equal(mine.status, 404, "this machine's own origin is served");

  // Another site on the internet is still refused: the allowlist widened to
  // the machine's own addresses, not to everything.
  const theirs = await fetch(`http://127.0.0.1:${port}/api/nope`, {
    headers: { Origin: "http://evil.example.com" },
  });
  assert.equal(theirs.status, 403, "an unrelated origin is refused");
});

test("a local origin is answered without asking the tailnet", async () => {
  // The phone browses this server by its tailnet address, and Safari sends an
  // Origin on every request. Asking the tailnet takes seconds — it probes
  // every online peer — so a local origin must be answered from the
  // interfaces alone.
  let dnsLookups = 0;
  let peerLookups = 0;
  const allowed = await isAllowedOrigin("http://100.64.99.99:3456", {
    local: new Set(["100.64.99.99:3456"]),
    magicDnsNames: async () => { dnsLookups += 1; return new Set(); },
    peerAuthorities: async () => { peerLookups += 1; return new Set(); },
  });
  assert.equal(allowed, true, "this machine's own origin is allowed");
  assert.equal(dnsLookups, 0, "tailscale is not asked for");
  assert.equal(peerLookups, 0, "the peers are not probed for");
});

test("an unknown origin is still checked against the mesh peers", async () => {
  // The short-circuit above must not have cost the cross-origin failover:
  // the web UI calls a peer, and that peer's origin is not local.
  let peerLookups = 0;
  const allowed = await isAllowedOrigin("http://peer-box:3456", {
    local: new Set(["100.64.99.99:3456"]),
    magicDnsNames: async () => new Set(),
    peerAuthorities: async () => { peerLookups += 1; return new Set(["peer-box:3456"]); },
  });
  assert.equal(allowed, true, "a peer's own origin is allowed");
  assert.equal(peerLookups, 1, "the peers are probed for");

  const refused = await isAllowedOrigin("http://evil.example.com", {
    local: new Set(["100.64.99.99:3456"]),
    magicDnsNames: async () => new Set(),
    peerAuthorities: async () => new Set(["peer-box:3456"]),
  });
  assert.equal(refused, false, "an unrelated origin is refused");
});

test("a malformed origin is refused", async () => {
  // The gate is the only thing between a request and the API, so an Origin
  // that cannot be parsed must be refused rather than slipping through
  // because it failed to parse.
  for (const origin of ["not a url", "http://", "", undefined]) {
    assert.equal(await isAllowedOrigin(origin), false, `${JSON.stringify(origin)} is refused`);
  }
});

test("the bridge range is trusted only while the machine has the bridge", (t) => {
  // No bridge: a connection claiming to come from the bridge range is a
  // Wi-Fi LAN that happens to reuse those addresses, and gains nothing.
  t.mock.method(os, "networkInterfaces", () => ({ en0: [LAN] }));
  assert.equal(
    isTrustedSocket({ remoteAddress: "192.168.64.10", localAddress: "192.168.1.178" }),
    false,
  );
  // The bridge appears — the VM was booted, long after the server started.
  t.mock.method(os, "networkInterfaces", () => ({ bridge100: [BRIDGE] }));
  assert.equal(
    isTrustedSocket({ remoteAddress: "192.168.64.10", localAddress: "192.168.64.1" }),
    true,
  );
});
