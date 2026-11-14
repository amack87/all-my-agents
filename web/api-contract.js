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

// --- Shape checking ---

// The primitive types a shape may declare. "vocabulary" is a string that is
// one of the contract's status words, so a status field cannot drift onto a
// word the server never emits; "null" exists so an absent value can be
// spelled honestly.
const PRIMITIVES = {
  string: (v) => typeof v === "string",
  number: (v) => typeof v === "number",
  boolean: (v) => typeof v === "boolean",
  null: (v) => v === null,
  object: (v) => typeof v === "object" && v !== null && !Array.isArray(v),
  array: (v) => Array.isArray(v),
};

function isConforming(spec, value, ctx) {
  const types = Array.isArray(spec.type) ? spec.type : [spec.type];
  for (const type of types) {
    if (type === "vocabulary") {
      if (typeof value === "string" && ctx.vocabulary.includes(value)) return true;
      continue;
    }
    const check = PRIMITIVES[type];
    if (!check) continue;
    if (check(value)) {
      // Recurse only where a non-primitive carries more of itself to check.
      if (type === "array" && spec.items) {
        return value.every((item) => checkShape(spec.items, item, ctx).length === 0);
      }
      return true;
    }
  }
  return false;
}

/**
 * Check a served value against the shape the contract publishes for it.
 * Returns a list of problems; empty means the response keeps the contract.
 *
 * A declared field that is missing or of the wrong type is a problem, and a
 * field the response carries that the shape does not declare is also a
 * problem — publishing the API means new fields are a deliberate act.
 */
export function checkShape(shapeName, value, ctx, path = String(shapeName)) {
  // A string names a shape the contract defines; an object is an inline spec
  // (the field specs inside an object shape).
  const spec = typeof shapeName === "string" ? ctx.shapes?.[shapeName] : shapeName;
  if (!spec) return [`${path}: the contract does not define this shape`];
  const problems = [];

  if (Array.isArray(value) && spec.type === "array") {
    if (spec.items) {
      value.forEach((item, i) => problems.push(...checkShape(spec.items, item, ctx, `${path}.${i}`)));
    }
    return problems;
  }

  if (!isConforming(spec, value, ctx)) {
    problems.push(`${path}: expected ${JSON.stringify(spec.type)}`);
    return problems;
  }

  if (spec.fields) {
    for (const [key, fieldSpec] of Object.entries(spec.fields)) {
      if (!(key in value)) {
        if (!fieldSpec.optional) problems.push(`${path}.${key}: declared but missing`);
        continue;
      }
      problems.push(...checkShape(fieldSpec, value[key], ctx, `${path}.${key}`));
    }
    for (const key of Object.keys(value)) {
      if (!(key in spec.fields)) problems.push(`${path}.${key}: not declared by the shape`);
    }
  }
  return problems;
}
