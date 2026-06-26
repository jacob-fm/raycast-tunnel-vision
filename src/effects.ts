// Registry of "time's up" visual effects.
//
// This is the single source of truth for which effects exist and how they
// relate to one another. The Raycast form renders a checkbox per effect from
// this list, and the selected effect ids are passed straight through to the
// Swift overlay (see TunnelVisionOverlay.swift), which keys off the same ids.
// Keep the `id` values in sync with the `switch` in the overlay's effect
// factory — they are the contract between the two halves of the extension.

export interface TimeUpEffect {
  /** Stable identifier passed to the overlay binary. Must match the Swift side. */
  id: string;
  /** Text shown beside the checkbox in the form. */
  label: string;
  /** Longer explanation surfaced via the checkbox info tooltip. */
  description: string;
  /**
   * Ids of effects that cannot be active at the same time as this one. The
   * relationship is treated as symmetric, so listing it on either effect is
   * enough. When one of an incompatible pair is selected, the other is greyed
   * out in the form.
   */
  incompatibleWith: string[];
}

export const TIME_UP_EFFECTS: TimeUpEffect[] = [
  {
    id: "red",
    label: "Flash the text red",
    description:
      "When the timer ends, switch the HUD from neon green to alarm red.",
    incompatibleWith: [],
  },
  {
    id: "blue",
    label: "Flash the text blue",
    description:
      "When the timer ends, switch the HUD from neon green to electric blue.",
    incompatibleWith: ["red"],
  },
  {
    id: "zoom",
    label: "Zoom to fill the screen",
    description:
      "When the timer ends, glide the text to the center of the screen and grow it until it spans the full screen width.",
    incompatibleWith: [],
  },
];

/**
 * Given the currently-selected effect ids, return a map of effect id → the
 * label of the effect it conflicts with. Any effect present in this map should
 * be greyed out (and forced off) in the UI.
 */
export function disabledEffects(selected: Set<string>): Map<string, string> {
  const byId = new Map(TIME_UP_EFFECTS.map((e) => [e.id, e]));
  const disabled = new Map<string, string>();

  for (const effect of TIME_UP_EFFECTS) {
    if (selected.has(effect.id)) continue; // a selected effect is never greyed out
    for (const otherId of selected) {
      const other = byId.get(otherId);
      if (!other) continue;
      const conflicts =
        other.incompatibleWith.includes(effect.id) ||
        effect.incompatibleWith.includes(other.id);
      if (conflicts) {
        disabled.set(effect.id, other.label);
        break;
      }
    }
  }

  return disabled;
}
