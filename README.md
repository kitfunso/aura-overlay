# aura-overlay

Cross-app color identity for Windows 11. Draws a thin colored ring around any
window that belongs to a project, using the same repo = hue contract as
[aura](https://github.com/kitfunso/aura). Terminals with live Claude Code
sessions get their exact repo
color automatically; any other window (browser docs, Slack) can be tagged to
the current project with a hotkey.

Lane B of the aura design. The spike measurements that green-lit it are in
`aura/docs/LANE-B.md`. Architecture: `docs/ARCHITECTURE.md`.

## Quickstart

```
node bin/start.js        # start (detaches; prints "renderer pid N")
node bin/start.js --stop # clean stop (tray icon, rings, brain all gone)
```

Or quit from the tray icon (right-click the aura-overlay icon, Quit).

- `Ctrl+Alt+G` tags the focused window to the repo of your newest Claude Code
  session. The color freezes at tag time and survives restarts.
- `Ctrl+Alt+U` untags the focused window.
- Rings are click-through and never take focus (raw Win32, WS_EX_TRANSPARENT
  | WS_EX_NOACTIVATE at creation time).
- Everything is local. No network calls, no telemetry. Window titles are
  never logged.

## What gets a ring

In priority order, per window:

1. A tagged window (frozen identity from tag time).
2. A terminal window whose newest aura session maps it to a repo
   (reads aura's `state.json`, read-only). Rainbow-owned terminals
   (aura's "no project" marker) are skipped.
3. A process named in `paletteProcesses` (stable per-process palette color).

## Config

`%LOCALAPPDATA%\aura-overlay\config.json`:

```json
{"paletteProcesses":["chrome","slack"]}
```

Process names without `.exe`. Edit while running; the brain picks it up on
its next cycle. All runtime state lives in the same directory
(`rings.json`, `tags.json`, `tag-identities.json`, `renderer.log`).

## Autostart (opt-in, not installed by default)

Nothing registers itself. If you want it on logon, run once:

```
schtasks /Create /TN aura-overlay /SC ONLOGON /TR "node C:\path\to\aura-overlay\bin\start.js" /F
```

Remove with `schtasks /Delete /TN aura-overlay /F`.

## Requirements

Windows 11, Node.js 18+, PowerShell 5.1. aura installed (without it you
still get palette colors and manual tags).

## Development

Unit tests cover the brain's decision logic and the color-contract pin:
`node --test test/brain.test.js test/contract.test.js` from the repo root.

## Resident cost (measured 2026-08-30, 10 rings, 5.5 min soak)

- Steady state: 1.6 to 2.0% of one core combined (renderer + brain + scanner).
- Worst case, all 7 test windows dragged continuously for 30 s: 2.29%.
- Memory: renderer flat over the soak; brain +1.7 MB; the scanner warms up
  to a ~110 MB plateau (PowerShell 5.1 heap) and oscillates there, no
  growth trend. Zero focus changes caused by the overlay.

## Known limits

- Single monitor verified. Mixed-DPI multi-monitor and monitor hotplug are
  untested (this box has one display).
- Windows Terminal tabs share one window, so a WT window rings the color of
  the newest session among its tabs.
- Hotkeys already taken by another app are logged and skipped; rings and the
  other hotkey keep working.
