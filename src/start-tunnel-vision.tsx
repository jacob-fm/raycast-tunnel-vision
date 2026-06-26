import {
  Action,
  ActionPanel,
  Form,
  Icon,
  LocalStorage,
  closeMainWindow,
  environment,
  popToRoot,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { spawn } from "child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { TIME_UP_EFFECTS, disabledEffects } from "./effects";

const PID_FILE = join(environment.supportPath, "overlay.pid");
const PLACE_PID_FILE = join(environment.supportPath, "placement.pid");
const PLACEMENT_FILE = join(environment.supportPath, "placement.json");
const OVERLAY_BINARY = join(environment.assetsPath, "tunnelvision-overlay");

// Deeplink the placement-mode overlay opens after the user confirms, to bring them
// back to this form (pre-filled with the draft saved when they entered place mode).
const COMMAND_DEEPLINK =
  "raycast://extensions/jacob/tunnel-vision/start-tunnel-vision";

// Key under which the last-used form values are persisted so the command can
// reopen pre-filled with whatever you ran last.
const LAST_VALUES_KEY = "last-form-values";

interface StoredValues {
  goal: string;
  hours: string;
  minutes: string;
  seconds: string;
  effects: string[];
}

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

// Parse a single timer field into a non-negative integer (blank/garbage → 0).
function parseTimePart(value: string): number {
  const n = parseInt(value, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

// Validate a timer field, returning an error message (or undefined when valid).
// Blank is allowed (counts as 0); minutes and seconds must fall within 0–max.
function timePartError(value: string, max: number): string | undefined {
  const text = value.trim();
  if (text === "") return undefined;
  const n = Number(text);
  if (!Number.isInteger(n) || n < 0) return "Enter a whole number";
  if (n > max) return `Must be 0–${max}`;
  return undefined;
}

// Human-readable summary of a duration for the confirmation HUD, e.g. "1h 25m 30s".
function formatDuration(totalSeconds: number): string {
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  return [h && `${h}h`, m && `${m}m`, s && `${s}s`].filter(Boolean).join(" ");
}

// Best-effort SIGTERM of the process whose pid is recorded in `pidFile`.
function killByPidFile(pidFile: string) {
  try {
    if (!existsSync(pidFile)) return;
    const pid = parseInt(readFileSync(pidFile, "utf8").trim(), 10);
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

function stopExistingOverlay() {
  killByPidFile(PID_FILE);
}

function stopPlacementOverlay() {
  killByPidFile(PLACE_PID_FILE);
}

// Read the saved placement (if any) as the "centerX,centerY,fontSize" argument the
// overlay expects, or "" when none has been set.
function readPlacementArg(): string {
  try {
    if (!existsSync(PLACEMENT_FILE)) return "";
    const p = JSON.parse(readFileSync(PLACEMENT_FILE, "utf8"));
    if (
      typeof p?.centerX === "number" &&
      typeof p?.centerY === "number" &&
      typeof p?.fontSize === "number"
    ) {
      return `${p.centerX},${p.centerY},${p.fontSize}`;
    }
  } catch {
    // ignore corrupt/missing placement
  }
  return "";
}

export default function Command() {
  // Which time's-up effects are toggled on, keyed by effect id.
  const [enabled, setEnabled] = useState<Record<string, boolean>>({});

  // Live validation errors for the minutes/seconds fields. While either is set,
  // Raycast keeps the form's submit action disabled until it's resolved.
  const [minutesError, setMinutesError] = useState<string | undefined>();
  const [secondsError, setSecondsError] = useState<string | undefined>();

  // All fields are controlled so they can be pre-filled with the last-used values
  // loaded from LocalStorage (and so the timer drives the effect availability).
  const [goal, setGoal] = useState("");
  const [hours, setHours] = useState("");
  const [minutes, setMinutes] = useState("");
  const [seconds, setSeconds] = useState("");

  // Restore the last-used values when the command opens.
  useEffect(() => {
    (async () => {
      const raw = await LocalStorage.getItem<string>(LAST_VALUES_KEY);
      if (!raw) return;
      try {
        const stored = JSON.parse(raw) as Partial<StoredValues>;
        setGoal(stored.goal ?? "");
        setHours(stored.hours ?? "");
        setMinutes(stored.minutes ?? "");
        setSeconds(stored.seconds ?? "");
        setEnabled(
          Object.fromEntries((stored.effects ?? []).map((id) => [id, true])),
        );
      } catch {
        // Ignore corrupt storage and start blank.
      }
    })();
  }, []);
  const hasTimer =
    parseTimePart(hours) * 3600 +
      parseTimePart(minutes) * 60 +
      parseTimePart(seconds) >
    0;

  const selected = new Set(
    TIME_UP_EFFECTS.filter((e) => enabled[e.id]).map((e) => e.id),
  );
  const incompatible = disabledEffects(selected);

  // Reset every field back to empty.
  function clearFields() {
    setGoal("");
    setHours("");
    setMinutes("");
    setSeconds("");
    setEnabled({});
    setMinutesError(undefined);
    setSecondsError(undefined);
  }

  // Why an effect is unavailable (undefined = available). A timer is required;
  // beyond that, an effect can be blocked by an incompatible selection.
  function effectDisabledReason(id: string): string | undefined {
    if (!hasTimer) return "set a timer first";
    const conflict = incompatible.get(id);
    return conflict ? `conflicts with “${conflict}”` : undefined;
  }

  // The effects that are toggled on AND currently available.
  function activeEffectIds(): string[] {
    return TIME_UP_EFFECTS.filter(
      (e) => enabled[e.id] && !effectDisabledReason(e.id),
    ).map((e) => e.id);
  }

  // Snapshot of the current form, persisted so the command can restore it.
  function currentDraft(): StoredValues {
    return { goal, hours, minutes, seconds, effects: activeEffectIds() };
  }

  // ⌘H: open the on-screen placement preview. This must hand focus to the overlay,
  // so we save the in-progress draft (restored when the overlay reopens the command
  // via deeplink) and close the Raycast window.
  async function handleConfigurePlacement() {
    if (!existsSync(OVERLAY_BINARY)) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Overlay not built",
        message: "Run `npm run build:overlay` to compile the helper.",
      });
      return;
    }

    await LocalStorage.setItem(LAST_VALUES_KEY, JSON.stringify(currentDraft()));
    stopPlacementOverlay(); // replace any previous placement window

    try {
      chmodSync(OVERLAY_BINARY, 0o755);
    } catch {
      // permission bit is usually already set
    }

    const sampleSeconds =
      parseTimePart(hours) * 3600 +
      parseTimePart(minutes) * 60 +
      parseTimePart(seconds);

    const child = spawn(
      OVERLAY_BINARY,
      [
        "place",
        PLACEMENT_FILE,
        goal.trim() || "Focus",
        String(sampleSeconds),
        COMMAND_DEEPLINK,
      ],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
    if (child.pid) {
      writeFileSync(PLACE_PID_FILE, String(child.pid));
    }

    await closeMainWindow({ clearRootSearch: true });
    await showHUD(
      "Drag to position · drag the handle to resize · Enter to confirm",
    );
  }

  async function handleSubmit(values: FormValues) {
    const goal = values.goal.trim();
    if (!goal) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Enter a goal to focus on",
      });
      return;
    }

    // Backstop in case a value was pasted/submitted without firing onChange.
    const mErr = timePartError(values.minutes, 59);
    const sErr = timePartError(values.seconds, 59);
    if (mErr || sErr) {
      setMinutesError(mErr);
      setSecondsError(sErr);
      await showToast({
        style: Toast.Style.Failure,
        title: "Fix the timer",
        message: "Minutes and seconds must be 0–59",
      });
      return;
    }

    // Only the effects that are both toggled on and not greyed out (no timer, or
    // suppressed by an incompatible choice) get handed to the overlay.
    const activeEffects = activeEffectIds();

    const seconds =
      parseTimePart(values.hours) * 3600 +
      parseTimePart(values.minutes) * 60 +
      parseTimePart(values.seconds);

    if (!existsSync(OVERLAY_BINARY)) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Overlay not built",
        message: "Run `npm run build:overlay` to compile the helper.",
      });
      return;
    }

    // Only one HUD at a time; also dismiss any open placement preview.
    stopExistingOverlay();
    stopPlacementOverlay();

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
        readPlacementArg(), // "centerX,centerY,fontSize" or "" for default placement
      ],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
    if (child.pid) {
      writeFileSync(PID_FILE, String(child.pid));
    }

    // Remember these values so the command reopens pre-filled next time.
    const toStore: StoredValues = {
      goal,
      hours: values.hours,
      minutes: values.minutes,
      seconds: values.seconds,
      effects: activeEffects,
    };
    await LocalStorage.setItem(LAST_VALUES_KEY, JSON.stringify(toStore));

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
          <Action
            title="Position & Size on Screen"
            icon={Icon.Maximize}
            shortcut={{ modifiers: ["cmd"], key: "h" }}
            onAction={handleConfigurePlacement}
          />
          <Action
            title="Clear All Fields"
            icon={Icon.Trash}
            shortcut={{ modifiers: ["cmd", "shift"], key: "x" }}
            onAction={clearFields}
          />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="goal"
        title="Goal"
        placeholder="What are you locking in on?"
        autoFocus
        value={goal}
        onChange={setGoal}
      />
      <Form.TextField
        id="hours"
        title="Timer"
        placeholder="Hours"
        value={hours}
        onChange={setHours}
      />
      <Form.TextField
        id="minutes"
        placeholder="Minutes (0–59)"
        value={minutes}
        error={minutesError}
        onChange={(value) => {
          setMinutes(value);
          setMinutesError(timePartError(value, 59));
        }}
      />
      <Form.TextField
        id="seconds"
        placeholder="Seconds (0–59)"
        value={seconds}
        error={secondsError}
        onChange={(value) => {
          setSeconds(value);
          setSecondsError(timePartError(value, 59));
        }}
      />
      <Form.Description text="Optional countdown — leave the timer blank for a goal-only HUD. Minutes and seconds must be 0–59. Press ⌘H to drag/resize where the HUD appears on screen. A glowing green HUD pins your goal until you stop Tunnel Vision." />
      <Form.Separator />
      {TIME_UP_EFFECTS.map((effect, index) => {
        const disabledReason = effectDisabledReason(effect.id);
        const isDisabled = disabledReason !== undefined;
        return (
          <Form.Checkbox
            key={effect.id}
            id={`effect-${effect.id}`}
            // Only the first checkbox carries the column label, so they read as one group.
            title={index === 0 ? "When time's up" : ""}
            label={
              isDisabled
                ? `${effect.label}  —  disabled (${disabledReason})`
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
