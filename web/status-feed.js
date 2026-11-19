// The status push channel.
//
// The server discovers sessions by capturing every tmux pane — one subprocess
// per pane, per discovery. Clients that want the session list used to ask for
// it over HTTP, so every client paid for its own discovery pass.
//
// This feed is the one place that discovers. While at least one client is
// subscribed, a ticker drives discovery and pushes a full snapshot to
// everyone. Clients that ask over HTTP share the same snapshot. When nobody
// is subscribed the ticker stops, so an idle server costs exactly what it
// cost before.

/// A fingerprint of the parts of a snapshot a client can see. Two snapshots
/// with the same signature would render identically, so there is no point
/// pushing the second one.
export function snapshotSignature(snapshot) {
  const sessions = (snapshot?.sessions ?? [])
    .map(
      (s) =>
        `${s.name}|${s.paneId ?? ""}|${s.status}|${s.agent ?? ""}|${s.lastActivity ?? 0}|${s.task ?? ""}`,
    )
    .sort()
    .join("\n");
  const peers = Object.entries(snapshot?.peerStatus ?? {})
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([name, state]) => `${name}=${state}`)
    .join("\n");
  return `${sessions}\n--\n${peers}`;
}

/**
 * Create a status feed.
 *
 * `discover` returns the current snapshot. `onTick` is called after every
 * ticker-driven refresh, whether or not anything changed — it exists so a
 * caller can observe the feed's cadence. Subscribers are `{ send(message) }`
 * objects; every message they receive is a full snapshot.
 */
export function createStatusFeed({
  discover,
  onTick,
  intervalMs = 1000,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
} = {}) {
  const subscribers = new Set();
  let timer = null;
  let snapshot = null;
  let inFlight = null;

  function messageFor(next) {
    return {
      type: "sessions",
      sessions: next.sessions ?? [],
      peerStatus: next.peerStatus ?? {},
    };
  }

  function sendTo(subscriber, message) {
    try {
      subscriber.send(message);
    } catch {
      // A subscriber that cannot take the message is a dead socket; the
      // close handler will drop it.
    }
  }

  function push(next) {
    const message = messageFor(next);
    for (const subscriber of subscribers) {
      sendTo(subscriber, message);
    }
  }

  async function refresh() {
    // Overlapping refreshes share one discovery pass — a slow discovery must
    // not be multiplied by the number of clients asking for it.
    if (inFlight) return inFlight;
    inFlight = (async () => {
      try {
        const next = await discover();
        const changed = !snapshot || snapshotSignature(next) !== snapshotSignature(snapshot);
        snapshot = next;
        if (changed) push(next);
        return next;
      } finally {
        inFlight = null;
      }
    })();
    try {
      return await inFlight;
    } catch {
      // A failed discovery leaves the previous snapshot in place; the next
      // tick tries again.
      return snapshot;
    }
  }

  function start() {
    if (timer) return;
    timer = setIntervalFn(() => {
      refresh().finally(() => onTick?.());
    }, intervalMs);
    timer.unref?.();
  }

  function stop() {
    if (!timer) return;
    clearIntervalFn(timer);
    timer = null;
  }

  return {
    /** Add a subscriber and hand it the current snapshot straight away. */
    async subscribe(subscriber) {
      subscribers.add(subscriber);
      start();
      // The subscriber gets the current snapshot even when nothing has changed
      // since anybody last saw it. A push only happens on a change, so without
      // this a client that joins later would wait in silence until the next
      // change — which may be never.
      if (snapshot) sendTo(subscriber, messageFor(snapshot));
      await refresh();
      return subscriber;
    },

    /** Drop a subscriber; the ticker stops when the last one leaves. */
    unsubscribe(subscriber) {
      subscribers.delete(subscriber);
      if (subscribers.size === 0) stop();
    },

    /** Discover now and push if anything changed. */
    refreshNow: refresh,

    /** The most recent snapshot, or null if discovery has never succeeded. */
    get current() {
      return snapshot;
    },

    get subscriberCount() {
      return subscribers.size;
    },

    /** Whether the ticker is running — i.e. whether discovery is being driven. */
    get isRunning() {
      return timer !== null;
    },
  };
}
