# aura-overlay - Architecture

## System Overview

Two resident processes, one shared data file:

- **brain** (`src/brain.js`, node): every 2 s, enumerates visible windows
  (via `src/detect-win.ps1`), reads aura's `state.json` (read-only) and the
  local `tags.json` + `config.json`, maps each window to an identity, runs
  it through `src/color.js`, and writes the desired ring set to
  `rings.json` (atomic write, only when changed).
- **renderer** (`src/renderer-win.ps1`, PowerShell 5.1): owns one raw Win32
  window class and N ring windows. A 30 ms WM_TIMER tick tracks every ring's
  target rect (`DWMWA_EXTENDED_FRAME_BOUNDS`) and reloads `rings.json` when
  its mtime changes (create/destroy/recolor rings). Also owns the tray
  NotifyIcon (Quit) and the tag hotkeys, and spawns/kills the brain.
- **launcher** (`bin/start.js`): starts the renderer hidden via the
  `Start-Process` double-hop (children of a dying tree die with it,
  measured in aura); `--stop` asks a running renderer to quit.

## Data Flow (primary loop)

1. brain scan -> window list [{hwnd, pid, process, title}].
2. Identity per window, first match wins:
   a. `tags.json` entry for the hwnd (+pid match) -> the tag's frozen
      repoId/branch.
   b. Terminal process (aura's allowlist) with sessions in aura state.json
      on that hwnd -> newest session's repoId/branch, unless
      `frameOwner[hwnd] == "rainbow"` (Lane A already marks those) -> no ring.
   c. Process name in `config.json` paletteProcesses -> process name as
      repoId (deterministic palette color).
   d. Otherwise -> no ring.
3. `colorsFor({repoId, branch})` -> frameHex. Ring set = [{hwnd, hex}].
4. rings.json changed -> renderer reconciles: destroy rings whose hwnd left
   the set, create new ones, recolor changed ones (destroy + recreate; a
   ring window is cheap).
5. Renderer tick per ring: target gone -> destroy ring; minimized -> hide;
   rect changed -> SetWindowPos + refresh the region ring.

## Tagging

`Ctrl+Alt+G` (renderer, RegisterHotKey): append {hwnd, pid, resolved: false}
to `tags.json`. The brain resolves a new tag ONCE to the newest aura
session's identity at tag time and rewrites the entry with frozen
repoId/branch (a tag must not change color when the user switches repos).
`Ctrl+Alt+U`: remove the foreground window's tag. Brain prunes tags whose
window or process is gone.

## Files

| File | Owner (writes) | Readers |
|---|---|---|
| `%LOCALAPPDATA%/aura-overlay/rings.json` | brain | renderer |
| `%LOCALAPPDATA%/aura-overlay/tags.json` | renderer (add/remove), brain (resolve/prune) | brain |
| `%LOCALAPPDATA%/aura-overlay/config.json` | user | brain |
| `%LOCALAPPDATA%/aura/state.json` | aura (Lane A) ONLY | brain, read-only |

Two writers touch `tags.json` (renderer on hotkey, brain on resolve/prune);
both write atomically (temp + rename) and re-read before writing, and the
worst race outcome is a tag reverting to unresolved for one 2 s cycle.

## The contract pin

`src/color.js` is a byte-identical copy of aura's. The consumed
`state.json` interface is pinned to: `sessions[id].{hwnd, repoId, branch,
updatedAt}` and `frameOwner[hwndKey]`. If aura changes either, this repo
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
- Windows Terminal runs every window in one process; hwnd, never pid, is
  the window key.
