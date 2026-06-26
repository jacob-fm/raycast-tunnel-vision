import {
  Action,
  ActionPanel,
  Form,
  closeMainWindow,
  environment,
  popToRoot,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useState } from "react";
import { spawn } from "child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { TIME_UP_EFFECTS, disabledEffects } from "./effects";

const PID_FILE = join(environment.supportPath, "overlay.pid");
const OVERLAY_BINARY = join(environment.assetsPath, "tunnelvision-overlay");

// Inactivity threshold (seconds the cursor can sit still near the HUD before it
// snaps back into view). Surfaced here so we can tune it easily later.
const INACTIVITY_THRESHOLD = 0.5;
// Hot-zone padding (points around the HUD that count as "near"). Passed
// positionally to the overlay so the effects argument can follow it.
const NEAR_MARGIN = 90;

interface FormValues {
  goal: string;
  hours: string;
  minutes: string;
  seconds: string;
}

// Parse a single timer field into a non-negative integer (blank/garbage → 0),
// optionally clamped to a maximum (minutes and seconds are capped at 59).
function parseTimePart(value: string, max = Infinity): number {
  const n = parseInt(value, 10);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(n, max);
}

// Human-readable summary of a duration for the confirmation HUD, e.g. "1h 25m 30s".
function formatDuration(totalSeconds: number): string {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return [h && `${h}h`, m && `${m}m`, s && `${s}s`].filter(Boolean).join(" ");
}

function stopExistingOverlay() {
  try {
    if (!existsSync(PID_FILE)) return;
    const pid = parseInt(readFileSync(PID_FILE, "utf8").trim(), 10);
    if (pid > 0) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        // already gone
      }
    }
  } catch {
    // ignore — best effort
  }
}

export default function Command() {
  // Which time's-up effects are toggled on, keyed by effect id.
  const [enabled, setEnabled] = useState<Record<string, boolean>>({});

  const selected = new Set(
    TIME_UP_EFFECTS.filter((e) => enabled[e.id]).map((e) => e.id),
  );
  const disabled = disabledEffects(selected);

  async function handleSubmit(values: FormValues) {
    const goal = values.goal.trim();
    if (!goal) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Enter a goal to focus on",
      });
      return;
    }

    // Only the effects that are both toggled on and not greyed out (i.e. not
    // suppressed by an incompatible choice) get handed to the overlay.
    const activeEffects = TIME_UP_EFFECTS.filter(
      (e) => enabled[e.id] && !disabled.has(e.id),
    ).map((e) => e.id);

    const seconds =
      parseTimePart(values.hours) * 3600 +
      parseTimePart(values.minutes, 59) * 60 +
      parseTimePart(values.seconds, 59);

    if (!existsSync(OVERLAY_BINARY)) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Overlay not built",
        message: "Run `npm run build:overlay` to compile the helper.",
      });
      return;
    }

    // Only one HUD at a time.
    stopExistingOverlay();

    try {
      chmodSync(OVERLAY_BINARY, 0o755);
    } catch {
      // permission bit is usually already set
    }

    const child = spawn(
      OVERLAY_BINARY,
      [
        goal,
        String(seconds),
        String(INACTIVITY_THRESHOLD),
        String(NEAR_MARGIN),
        activeEffects.join(","),
      ],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
    if (child.pid) {
      writeFileSync(PID_FILE, String(child.pid));
    }

    await closeMainWindow({ clearRootSearch: true });
    await showHUD(
      seconds > 0
        ? `🟢 Tunnel vision: ${goal} (${formatDuration(seconds)})`
        : `🟢 Tunnel vision: ${goal}`,
    );
    await popToRoot();
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Start Tunnel Vision"
            onSubmit={handleSubmit}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="goal"
        title="Goal"
        placeholder="What are you locking in on?"
        autoFocus
      />
      <Form.TextField id="hours" title="Timer" placeholder="Hours" />
      <Form.TextField id="minutes" placeholder="Minutes (0–59)" />
      <Form.TextField id="seconds" placeholder="Seconds (0–59)" />
      <Form.Description text="Optional countdown — leave the timer blank for a goal-only HUD. Minutes and seconds clamp to 0–59. A glowing green HUD pins your goal to the top of the screen until you stop Tunnel Vision." />
      <Form.Separator />
      {TIME_UP_EFFECTS.map((effect, index) => {
        const conflictsWith = disabled.get(effect.id);
        const isDisabled = conflictsWith !== undefined;
        return (
          <Form.Checkbox
            key={effect.id}
            id={`effect-${effect.id}`}
            // Only the first checkbox carries the column label, so they read as one group.
            title={index === 0 ? "When time's up" : ""}
            label={
              isDisabled
                ? `${effect.label}  —  disabled (conflicts with “${conflictsWith}”)`
                : effect.label
            }
            info={effect.description}
            value={isDisabled ? false : !!enabled[effect.id]}
            onChange={(value) => {
              // Greyed-out effects can't be toggled on.
              if (isDisabled) return;
              setEnabled((prev) => ({ ...prev, [effect.id]: value }));
            }}
          />
        );
      })}
    </Form>
  );
}
