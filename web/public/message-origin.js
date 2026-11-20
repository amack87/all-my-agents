// The message origin rule, in one place on the web side. The rule itself is
// spelled out in `contract/message-origin.json`, asserted by both suites —
// the macOS app resolves the same fixture. A panel message is exactly one
// whose origin is the panel's origin.

export const PANEL_ORIGIN = "panel";
export const AGENT_ORIGIN = "agent";

/** Is this message a reply typed in the chat panel? */
export function isPanelMessage(message) {
  return message?.origin === PANEL_ORIGIN;
}
