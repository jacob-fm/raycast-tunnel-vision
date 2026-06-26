# Tunnel Vision

A Raycast extension that helps you lock onto a single goal. When you start a session, a deliberately obtrusive, glowing green HUD pins your goal — and an optional countdown timer — to the top of your screen. It stays in your face until you stop it, and only gets out of the way when you actively reach for the area it occupies.

## What it does

- **Start Tunnel Vision** — enter a goal and an optional timer via separate hours, minutes, and seconds fields (minutes and seconds must be 0–59; the form shows an error and blocks submission otherwise). A neon-green HUD appears near the top-center of your screen showing `Goal · MM:SS`.
- **Stop Tunnel Vision** — dismisses the HUD.
- **Place Tunnel Vision** — opens the on-screen placement preview directly (the same thing the Start form's ⌘H shortcut does). **Drag** the preview to reposition, **drag the bottom-right handle** to scale the text, then press **Enter** to save (or **⌘Enter** to also save it as your default; **Esc** cancels). Then run **Start Tunnel Vision** and the HUD launches at the position and size you chose. The preview uses your last-used goal/timer.
- **Smart transparency** — the HUD's solid text fades out _only while your cursor is near it and actively moving_, so you can interact with whatever is underneath. While faded it leaves a dashed light-grey outline of the text, so your goal stays faintly legible. If the cursor goes still for more than 0.5s (tunable), the HUD snaps back to full opacity even while you hover.
- **Time's-up effects** — opt into one or more visual effects that fire when the countdown reaches zero:
  - **Flash the text red** — fades the HUD from neon green to alarm red.
  - **Flash the text blue** — fades the HUD from neon green to electric blue. (Incompatible with red.)
  - **Zoom to fill the screen** — glides the text to screen center and grows it until it spans the full screen width.

  These require a timer — without a countdown there's no "time's up" moment, so the options are greyed out until you enter one. Effects stack: enable as many as you like. When two effects are incompatible (like red and blue), selecting one disables the other in the form.

## Defaults & remembered values

- **Remembered values** — the Start form reopens pre-filled with whatever you last ran (goal, timer, effects). Press **⌘⇧X — Reset to Defaults** to clear back to your configured defaults: effects return to the settings defaults, the goal/timer blank out, and the HUD placement reverts to your saved default.
- **Configurable defaults (extension settings)** — in Raycast's settings for Start Tunnel Vision you can set a **default time's-up color** (None / Red / Blue — mutually exclusive) and toggle **zoom on by default**. Goal and timer have no defaults on purpose — they're meant to be decided every session.
- **Default placement** — there's no text field for size/position; instead, set it in placement mode with **⌘Enter ("save as default")**. Plain **Enter** saves the active placement used by your next session; the active placement wins at launch, falling back to your saved default, then the built-in top-center spot.

### Adding a new time's-up effect

Effects live in a small registry so they can be composed. To add one:

1. Append an entry to `TIME_UP_EFFECTS` in `src/effects.ts` (give it a stable `id`, a `label`, a `description`, and any `incompatibleWith` ids). This drives the form checkboxes and the greying-out logic automatically.
2. Add a matching `case "<id>":` returning a `TimeUpEffect` in `makeEffect(...)` in `overlay/TunnelVisionOverlay.swift`. An effect just mutates the shared `RenderStyle` (color, glow, font size, window frame) by an eased `progress` ramp, so independent effects compose without knowing about each other.

## How it's built

Raycast extensions render their UI _inside_ the Raycast window — they can't draw a free-floating, always-on-top overlay on screen. So Tunnel Vision is two pieces:

| Piece                                | Location                            | Role                                                                                         |
| ------------------------------------ | ----------------------------------- | -------------------------------------------------------------------------------------------- |
| Raycast extension (TypeScript/React) | `src/`                              | The control surface: a form to start a session, and a command to stop it.                    |
| Native overlay helper (Swift/AppKit) | `overlay/TunnelVisionOverlay.swift` | The borderless, always-on-top, click-through HUD. Compiled to `assets/tunnelvision-overlay`. |

The Start command spawns the compiled Swift binary (passing the goal, duration, inactivity threshold, hot-zone margin, the selected time's-up effect ids, and the optional saved placement) and records its PID; the Stop command kills it.

The same binary has a second `place` subcommand for the positioning preview (reached via the **Place Tunnel Vision** command or the Start form's ⌘H shortcut): it opens a full-screen, focus-grabbing, interactive window where you drag/resize the HUD. **Enter** writes the chosen `{centerX, centerY, fontSize}` to `placement.json` (the active placement); **⌘Enter** also writes `default-placement.json` (the saved default). The Start command reads the active placement on submit, falling back to the default, then the built-in spot. Because it needs mouse and keyboard focus, entering place mode closes the Raycast window (the in-progress form draft is saved to local storage and restored when you reopen the command). It deliberately does **not** try to deeplink back into Raycast — that scheme can't reliably target the right build (regular vs. Beta vs. dev), so you reopen the command yourself.

```
src/start-tunnel-vision.tsx   Form → launches the overlay (live HUD or place mode)
src/place-tunnel-vision.ts    Jumps straight into the placement preview
src/overlay.ts                Shared overlay/placement plumbing (paths, helpers)
src/effects.ts                Registry of time's-up effects (shared contract)
src/stop-tunnel-vision.ts     Kills the overlay
overlay/TunnelVisionOverlay.swift   The on-screen HUD + effect engine + place mode
scripts/generate-icon.js      Generates the extension icon
assets/extension-icon.png     Extension icon
```

## Requirements

- macOS with [Raycast](https://raycast.com) installed
- Node.js (with npm)
- Xcode command line tools (provides `swiftc`, used to compile the overlay)

## Develop & test

Install dependencies:

```sh
npm install
```

Start the dev loop. This compiles the Swift overlay, then loads the extension into Raycast with hot reload:

```sh
npm run dev
```

Now open Raycast and run **Start Tunnel Vision**. Enter a goal (and optionally a timer), submit, and the HUD appears. Run **Stop Tunnel Vision** to dismiss it. Edits to the TypeScript hot-reload automatically; after changing the Swift overlay, restart `npm run dev` to recompile it.

### Other scripts

```sh
npm run build:overlay   # recompile just the Swift overlay binary
npm run icon            # regenerate assets/extension-icon.png
npm run build           # production build of the extension
npm run lint            # lint via the Raycast CLI
```

## Tuning the feel

- **Inactivity threshold** (how long the cursor can sit still before the HUD reappears, default `0.5s`): `INACTIVITY_THRESHOLD` in `src/start-tunnel-vision.tsx`.
- **Hot-zone padding, colors, font size, glow, screen position**: top of `overlay/TunnelVisionOverlay.swift`.

## Notes

- The compiled overlay binary (`assets/tunnelvision-overlay`) is git-ignored and rebuilt from source via `npm run build:overlay`.
- Mouse tracking uses cursor-position polling, so the overlay does **not** require Accessibility permissions.
