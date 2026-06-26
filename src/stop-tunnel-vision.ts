import { environment, showHUD } from "@raycast/api";
import { execSync } from "child_process";
import { existsSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";

const PID_FILE = join(environment.supportPath, "overlay.pid");

export default async function Command() {
  let stopped = false;

  if (existsSync(PID_FILE)) {
    const pid = parseInt(readFileSync(PID_FILE, "utf8").trim(), 10);
    if (pid > 0) {
      try {
        process.kill(pid, "SIGTERM");
        stopped = true;
      } catch {
        // process no longer exists
      }
    }
    try {
      unlinkSync(PID_FILE);
    } catch {
      // ignore
    }
  }

  // Fallback: clean up any stray overlay processes.
  try {
    execSync("pkill -f tunnelvision-overlay");
    stopped = true;
  } catch {
    // pkill exits non-zero when nothing matched — fine
  }

  await showHUD(stopped ? "⚪️ Tunnel vision disengaged" : "Nothing to disengage");
}
