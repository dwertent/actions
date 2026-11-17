// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026-Present The Zarf Authors

/** Hidden markers a bot writes into its own descriptions and comments to find its text again. */
export interface BotMarkers {
  /** Allowed HTML comment contents (`<!-- ... -->`), matched against the trimmed text. */
  html: readonly RegExp[]
  /** Allowed Markdown link-reference comment contents (`[//]: # (...)`). */
  markdown: readonly RegExp[]
}

export const NO_MARKERS: BotMarkers = { html: [], markdown: [] }

/**
 * Bots whose markers can be allowed with `trusted-bots`. Keys are GitHub logins. A login ending in `[bot]`
 * belongs to a GitHub App and cannot be registered by a user, because user names cannot contain brackets.
 * Patterns are anchored and narrow, so that anything else hidden in the bot's text (for example in release
 * notes it copies from a dependency) is still reported.
 */
export const KNOWN_BOTS: Readonly<Record<string, BotMarkers>> = {
  // e.g. `[//]: # (dependabot-automerge-start)`
  'dependabot[bot]': { html: [], markdown: [/^dependabot-[a-z]+(?:-[a-z]+)*$/u] }
}

export function markersFor(logins: readonly string[]): BotMarkers {
  const bots = logins.map((login) => KNOWN_BOTS[login] ?? NO_MARKERS)
  return { html: bots.flatMap((b) => b.html), markdown: bots.flatMap((b) => b.markdown) }
}
