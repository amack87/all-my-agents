// The contract machinery: reading the server's real route table out of the
// Express app, checking the contract against it, checking the responses the
// server serves against the shapes the contract publishes, and building the
// document the server serves at GET /api/contract.
//
// Everything here is a pure function over plain data, so the tests exercise
// it against fake router stacks and shapes; server.js wires the real app,
// the real fixture and its own vocabulary into it.

/**
 * The server's real route table, derived from the Express router stack.
 *
 * Named parameters are normalized to `{name}`, the way the contract writes
 * them: Express spells them `:name`. express-ws registers its websocket
 * routes as `GET /ws/status/.websocket`; a client subscribes to /ws/status,
 * so those collapse to a single WS entry.
 */
export function routeTable(app) {
  const table = [];
  for (const layer of app?._router?.stack ?? []) {
    if (!layer.route) continue;
    const path = String(layer.route.path).replace(/:([A-Za-z0-9_]+)/g, "{$1}");
    if (path.endsWith("/.websocket")) {
      table.push({ method: "WS", path: path.slice(0, -"/.websocket".length) });
      continue;
    }
    const method =
      Object.keys(layer.route.methods ?? {}).find((m) => layer.route.methods[m])?.toUpperCase() ??
      "GET";
    table.push({ method, path });
  }
  return table;
}

/** Every contract route the given table does not serve. Empty means the contract tells the truth. */
export function missingContractRoutes(contract, table) {
  const served = new Set(table.map((r) => `${r.method} ${r.path}`));
  return Object.entries(contract.routes ?? {})
    .filter(([, route]) => !served.has(`${route.method} ${route.path}`))
    .map(([name, route]) => ({ name, method: route.method, path: route.path }));
}
