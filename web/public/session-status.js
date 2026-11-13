// The session status vocabulary, shared by the server, the web client and the
// macOS app. The canonical list lives in contract/status-vocabulary.json so
// neither app can drift from the other — see web/test/contract.test.js and
// Tests/AllMyAgentsTests/StatusVocabularyContractTests.swift.

export const STATUSES = ["needsInput", "working", "idle", "ended", "unknown"];

const STATUS_SET = new Set(STATUSES);

// Attention first, then work, then quiet. An ended session is more settled
// than an idle one; an unknown one is the last resort.
const PRIORITY = {
  needsInput: 0,
  working: 1,
  idle: 2,
  ended: 3,
  unknown: 4,
};

const LABELS = {
  needsInput: "Input",
  working: "Working",
  idle: "Idle",
  ended: "Ended",
  unknown: "...",
};

/** Coerce anything into one of the known statuses. */
export function normalizeStatus(status) {
  return STATUS_SET.has(status) ? status : "unknown";
}

/** The human-facing label for a status. */
export function statusLabel(status) {
  return LABELS[status] ?? LABELS.unknown;
}

/** The sort rank of a status — lower sorts first. */
export function statusPriority(status) {
  return PRIORITY[normalizeStatus(status)];
}

/**
 * Sort sessions by status priority, then by most recent activity first.
 * Returns a new array; the input is left alone.
 */
export function sortSessionsByStatus(sessions) {
  return [...sessions].sort((a, b) => {
    const byStatus = statusPriority(a.status) - statusPriority(b.status);
    if (byStatus !== 0) return byStatus;
    return (b.lastActivity ?? 0) - (a.lastActivity ?? 0);
  });
}
