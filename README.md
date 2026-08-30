# aura-overlay

Cross-app color identity for Windows 11. Draws a thin colored ring around any
window that belongs to a project, using the same repo = hue contract as
[aura](../aura). Terminals with live Claude Code sessions get their exact repo
color automatically; any other window (browser docs, Slack) can be tagged to
the current project with a hotkey.

Lane B of the aura design. The spike measurements that green-lit it are in
`aura/docs/LANE-B.md`.

## Status

MVP under construction. Plan: `docs/plans/2026-08-30-mvp.md`.

## How it will run

- `node bin/start.js` starts two resident processes: a node "brain" that
  decides which windows get which colors, and a PowerShell "renderer" that
  owns the ring windows, the tray icon, and the hotkeys.
- Rings are click-through and never take focus (raw Win32, WS_EX_TRANSPARENT
  | WS_EX_NOACTIVATE at creation).
- `Ctrl+Alt+G` tags the focused window to the repo you most recently worked
  in; `Ctrl+Alt+U` untags it. Quit from the tray icon.
- Everything is local. No network calls, no telemetry.

## Requirements

Windows 11, Node.js 18+, PowerShell 5.1. aura installed (the brain reads
aura's `state.json` read-only for terminal identities; without it you still
get palette colors and manual tags).
