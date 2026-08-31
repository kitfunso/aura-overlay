# aura-overlay - Architecture

## System Overview

Two resident processes, one shared data file:

- **brain** (`src/brain.js`, node): every 2 s, enumerates visible windows
  (via `src/detect-win.ps1`), reads aura's `state.json` (read-only) and the
  local `tags.json` + `config.json`, maps each window to an identity, runs
  it through `src/color.js`, and writes the desired ring set to
  `rings.json` (atomic write, only when changed). Exits on its own when
  the renderer pid it was launched with is gone (no orphan on a renderer
  crash). The scanner runs as one persistent PowerShell child for the
  brain's whole life; a fresh spawn per cycle would cost about 10% of a
  core on startup alone.
- **renderer** (`src/renderer-win.ps1`, PowerShell 5.1): owns one raw Win32
  window class and N ring windows. A 30 ms WM_TIMER tick tracks every ring's
  target rect (`DWMWA_EXTENDED_FRAME_BOUNDS`) and reloads `rings.json` when
  its mtime changes (create/destroy/recolor rings). Also owns the tray
  NotifyIcon (Quit) and the tag hotkeys, and spawns/kills the brain. Holds
  a named mutex; a second instance exits at once.
- **launcher** (`bin/start.js`): starts the renderer hidden via the
  `Start-Process` double-hop (children of a dying tree die with it,
  measured in aura); `--stop` writes `stop.flag` into the runtime dir; the
  renderer's tick sees it, deletes it, and quits cleanly (same polled-file
  pattern as rings.json, no extra Win32 IPC surface).

## Data Flow (primary loop)

1. brain scan -> window list [{hwnd, pid, process}]. Titles are used inside
   the scanner only as a liveness filter and never emitted (they can hold
   prompt text).
2. Identity per window, first match wins:
   a. `tags.json` entry for the hwnd (+pid match) whose frozen identity
      exists in `tag-identities.json` -> that repoId/branch. Unresolved
      tags get no ring yet.
   b. Terminal process (aura's allowlist) with sessions in aura state.json
      on that hwnd -> newest session's repoId/branch. Sessions aura left
      colorless are skipped, so a window whose only sessions are bare shells
      gets no ring (no identity, no color - Lane A does the same with the
      window frame), and a colored tab outranks a bare one beside it. The
      flag is `hasColor`; state written before aura shipped it only carries
      `isRepo`, and back then a repo was the only thing that got a color.
   c. Process name in `config.json` paletteProcesses -> process name as
      repoId (deterministic palette color). The shipped default is EMPTY:
      a default of ["chrome","slack"] made a fresh install ring the browser
      and nothing else, which reads as the tool coloring the wrong windows.
   d. Otherwise -> no ring.
3. `colorsFor({repoId, branch})` -> frameHex. Ring set = [{hwnd, pid, hex}].
4. rings.json changed -> renderer reconciles: destroy rings whose hwnd left
   the set, create new ones (only after IsWindow passes AND
   GetWindowThreadProcessId returns the entry's pid; hwnds recycle),
   recolor changed ones in place.
5. Renderer tick per ring: target gone or pid mismatch -> destroy ring;
   minimized -> hide; rect changed -> SetWindowPos + refresh the region
   ring; then pin the ring immediately above its target in z-order
   (`KeepAboveTarget`), so covering the target covers the ring. Rings are
   NOT topmost - the steady-state cost is one GetWindow(GW_HWNDPREV) read
   per ring per tick, and SetWindowPos only fires when the pin slipped.

## Tagging

`Ctrl+Alt+G` (renderer, RegisterHotKey): append {hwnd, pid, taggedAt} to
`tags.json`. `Ctrl+Alt+U`: remove the foreground window's entry. The
renderer also prunes entries whose window or process is gone. The brain
NEVER writes `tags.json`.

The brain resolves each tag ONCE and freezes it in `tag-identities.json`,
keyed `hwnd:pid:taggedAt` (a tag must not change color when the user
switches repos). It freezes to the newest aura session AT TAG TIME
(`updatedAt` at or before `taggedAt`), so a session whose agent turns
between the hotkey and the resolving cycle cannot steal the tag; if no
session predates the tag, it falls back to the newest overall. While no
aura session exists the tag stays unresolved: no ring, and the brain
retries every cycle until one appears. The brain prunes identities whose tag entry is
gone. The renderer never writes `tag-identities.json`.

## Files

| File | Owner (writes) | Readers |
|---|---|---|
| `%LOCALAPPDATA%/aura-overlay/rings.json` | brain | renderer |
| `%LOCALAPPDATA%/aura-overlay/tags.json` | renderer | brain |
| `%LOCALAPPDATA%/aura-overlay/tag-identities.json` | brain | brain |
| `%LOCALAPPDATA%/aura-overlay/config.json` | brain seeds defaults once; user edits after | brain |
| `%LOCALAPPDATA%/aura-overlay/stop.flag` | launcher `--stop` | renderer (deletes) |
| `%LOCALAPPDATA%/aura/state.json` | aura (Lane A) ONLY | brain, read-only |

Exactly ONE writer per shared file. The first design had two
read-modify-write writers on `tags.json`; that can silently LOSE a hotkey
add or remove, not just delay it, so tag facts (renderer) and frozen tag
identities (brain) live in separate files. All writes are atomic (temp +
rename); readers tolerate a missing or torn file by keeping their last
state.

## The contract pin

`src/color.js` is a byte-identical copy of aura's. The consumed
`state.json` interface is pinned to `sessions[id].{hwnd, repoId, branch,
isRepo, hasColor, updatedAt}`. If aura changes it, this repo
updates the same day; the hash check in CI-less reality is the Step 1
verify command in the MVP plan.

## Inherited measured findings (do not re-derive)

- Overlay ex-styles must exist at CreateWindowEx time; WinForms self-
  activates on first show (aura commit 98651c0).
- `DWMWA_EXTENDED_FRAME_BOUNDS` (9) is the visual rect; GetWindowRect
  floats.
- Region ring (outer rect minus inner rect) makes the center a non-window;
  WS_EX_TRANSPARENT makes the ring itself hit-test invisible.
- Spike cost: one ring at 30 ms poll = 0.72% CPU under continuous motion.
- Rebuilding a ring's clip region on every move (not just a resize) cost
  10% of a core with 7 windows dragging; SetWindowRgn forces a full
  repaint per call, so a pure move uses SetWindowPos with SWP_NOSIZE and
  skips the rebuild.
- Windows Terminal runs every window in one process; hwnd, never pid, is
  the window key.
