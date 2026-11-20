import { test } from "node:test";
import assert from "node:assert/strict";

import { messageLabel, appendMessages } from "../public/chat-panel.js";
import { isPanelMessage } from "../public/message-origin.js";

test("a message is labelled by who is speaking: the panel's reader, or the session", () => {
  const slice = "slice";
  assert.equal(
    messageLabel({ id: 1, text: "yes, approved", origin: "panel" }, slice),
    "You",
    "a panel reply is James's own voice",
  );
  assert.equal(
    messageLabel({ id: 2, text: "Done — tests pass.", origin: "agent" }, slice),
    "slice",
    "the agent speaks for its session",
  );
  assert.equal(
    messageLabel({ id: 3, text: "run the checks", origin: null }, slice),
    "slice",
    "an origin nobody declared still came out of the session",
  );
  assert.equal(
    isPanelMessage({ origin: "panel" }),
    true,
    "the label and the origin rule agree on which messages are the panel's",
  );
});

test("the panel's list grows by appending what the cursor has not seen, newest last", () => {
  const first = { id: 1, text: "one", origin: "agent" };
  const second = { id: 2, text: "two", origin: "panel" };
  const third = { id: 3, text: "three", origin: "agent" };

  let list = appendMessages([], [first, second]);
  assert.deepEqual(list, [first, second], "a page fills the list in the order it arrived");

  list = appendMessages(list, [second, third]);
  assert.deepEqual(list, [first, second, third], "an id already on screen is not drawn twice");

  list = appendMessages(list, []);
  assert.deepEqual(list, [first, second, third], "an empty page changes nothing");
});
