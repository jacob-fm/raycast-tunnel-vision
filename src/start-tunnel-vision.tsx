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
import { spawn } from "child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

const PID_FILE = join(environment.supportPath, "overlay.pid");
const OVERLAY_BINARY = join(environment.assetsPath, "tunnelvision-overlay");

// Inactivity threshold (seconds the cursor can sit still near the HUD before it
// snaps back into view). Surfaced here so we can tune it easily later.
const INACTIVITY_THRESHOLD = 0.5;

interface FormValues {
  goal: string;
  minutes: string;
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
  async function handleSubmit(values: FormValues) {
    const goal = values.goal.trim();
    if (!goal) {
      await showToast({ style: Toast.Style.Failure, title: "Enter a goal to focus on" });
      return;
    }

    const minutes = parseFloat(values.minutes);
    const seconds = Number.isFinite(minutes) && minutes > 0 ? Math.round(minutes * 60) : 0;

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
      [goal, String(seconds), String(INACTIVITY_THRESHOLD)],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
    if (child.pid) {
      writeFileSync(PID_FILE, String(child.pid));
    }

    await closeMainWindow({ clearRootSearch: true });
    await showHUD(seconds > 0 ? `🟢 Tunnel vision: ${goal} (${minutes}m)` : `🟢 Tunnel vision: ${goal}`);
    await popToRoot();
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Start Tunnel Vision" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField id="goal" title="Goal" placeholder="What are you locking in on?" autoFocus />
      <Form.TextField id="minutes" title="Timer (minutes)" placeholder="Optional — e.g. 25" />
      <Form.Description text="A glowing green HUD pins your goal to the top of the screen until you stop Tunnel Vision." />
    </Form>
  );
}
