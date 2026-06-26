// Shared plumbing for talking to the compiled Swift overlay binary. Used by the
// Start command (live HUD + ⌘H placement) and the standalone Place command.

import { environment } from "@raycast/api";
import { spawn } from "child_process";
import {
  chmodSync,
  existsSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { join } from "path";

export const PID_FILE = join(environment.supportPath, "overlay.pid");
export const PLACE_PID_FILE = join(environment.supportPath, "placement.pid");
// Active placement (plain Return) vs the saved default placement (⌘Return). On
// launch the active one wins, falling back to the default, then the built-in spot.
export const PLACEMENT_FILE = join(environment.supportPath, "placement.json");
export const DEFAULT_PLACEMENT_FILE = join(
  environment.supportPath,
  "default-placement.json",
);
export const OVERLAY_BINARY = join(
  environment.assetsPath,
  "tunnelvision-overlay",
);

// Key under which the last-used form values are persisted so the commands can
// pre-fill / preview whatever was run last.
export const LAST_VALUES_KEY = "last-form-values";

export interface StoredValues {
  goal: string;
  hours: string;
  minutes: string;
  seconds: string;
  effects: string[];
}

// Parse a single timer field into a non-negative integer (blank/garbage → 0).
export function parseTimePart(value: string): number {
  const n = parseInt(value, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

// Total seconds for a stored draft's timer fields.
export function storedDurationSeconds(stored: Partial<StoredValues>): number {
  return (
    parseTimePart(stored.hours ?? "") * 3600 +
    parseTimePart(stored.minutes ?? "") * 60 +
    parseTimePart(stored.seconds ?? "")
  );
}

// Best-effort SIGTERM of the process whose pid is recorded in `pidFile`.
export function killByPidFile(pidFile: string) {
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

export function stopExistingOverlay() {
  killByPidFile(PID_FILE);
}

export function stopPlacementOverlay() {
  killByPidFile(PLACE_PID_FILE);
}

// "centerX,centerY,fontSize" from a placement file, or "" if missing/invalid.
function placementArgFrom(file: string): string {
  try {
    if (!existsSync(file)) return "";
    const p = JSON.parse(readFileSync(file, "utf8"));
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

// The placement argument for launching the HUD: the active placement wins, falling
// back to the saved default, then "" (the overlay's built-in top-center spot).
export function readPlacementArg(): string {
  return (
    placementArgFrom(PLACEMENT_FILE) ||
    placementArgFrom(DEFAULT_PLACEMENT_FILE) ||
    ""
  );
}

// Revert to the default placement by dropping the active one (used by Reset).
export function resetActivePlacement() {
  try {
    if (existsSync(PLACEMENT_FILE)) unlinkSync(PLACEMENT_FILE);
  } catch {
    // ignore — best effort
  }
}

// Launch the overlay in interactive placement mode, previewing `goal` (and a sample
// time line when `sampleSeconds > 0`). Throws if the binary hasn't been built.
export function launchPlacementMode(goal: string, sampleSeconds: number) {
  if (!existsSync(OVERLAY_BINARY)) {
    throw new Error("Overlay not built");
  }
  try {
    chmodSync(OVERLAY_BINARY, 0o755);
  } catch {
    // permission bit is usually already set
  }

  stopPlacementOverlay(); // replace any previous placement window

  const child = spawn(
    OVERLAY_BINARY,
    [
      "place",
      PLACEMENT_FILE,
      DEFAULT_PLACEMENT_FILE,
      goal.trim() || "Focus",
      String(sampleSeconds),
    ],
    { detached: true, stdio: "ignore" },
  );
  child.unref();
  if (child.pid) {
    writeFileSync(PLACE_PID_FILE, String(child.pid));
  }
}
