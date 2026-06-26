import {
  LocalStorage,
  closeMainWindow,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import {
  LAST_VALUES_KEY,
  StoredValues,
  launchPlacementMode,
  storedDurationSeconds,
} from "./overlay";

// Jump straight into the on-screen placement preview, previewing the last-used goal
// and timer. Drag to move, drag the handle to resize, Enter to save / ⌘Enter to save
// as the default (Esc cancels), then run Start Tunnel Vision to launch at that spot.
export default async function Command() {
  let goal = "Focus";
  let sampleSeconds = 0;

  try {
    const raw = await LocalStorage.getItem<string>(LAST_VALUES_KEY);
    if (raw) {
      const stored = JSON.parse(raw) as Partial<StoredValues>;
      goal = (stored.goal ?? "").trim() || "Focus";
      sampleSeconds = storedDurationSeconds(stored);
    }
  } catch {
    // ignore corrupt storage — fall back to a generic preview
  }

  try {
    launchPlacementMode(goal, sampleSeconds);
  } catch {
    await showToast({
      style: Toast.Style.Failure,
      title: "Overlay not built",
      message: "Run `npm run build:overlay` to compile the helper.",
    });
    return;
  }

  await closeMainWindow({ clearRootSearch: true });
  await showHUD(
    "Drag to position · resize with the handle · Enter to save · ⌘Enter to save as default",
  );
}
