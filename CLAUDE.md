# CLAUDE.md - aura-overlay

## Project Overview
aura-overlay draws click-through colored rings around windows on Windows 11,
mapping windows to the same repo = hue contract as aura (Lane A). Resident
tray app: node brain (decides rings) + PowerShell renderer (owns ring
windows). Docs: `docs/ARCHITECTURE.md`; spike evidence: `aura/docs/LANE-B.md`.

## Non-Negotiable Rules
1. **`src/color.js` stays byte-identical to aura's copy.** Changes flow from
   aura to here, never the reverse; verify with a hash against
   `../aura/src/color.js`. Why: one color contract, two consumers; a fork
   means the same repo shows two colors.
2. **aura's `state.json` is READ-ONLY.** The brain reads it; nothing here
   ever writes it. Why: it is Lane A's own state file; a second writer
   corrupts the hook's caching.
3. **Overlay windows are raw Win32, created with their final ex-styles
   (LAYERED | TRANSPARENT | NOACTIVATE | TOOLWINDOW) at `CreateWindowEx`
   time.** WinForms is allowed ONLY for the tray NotifyIcon, never for a
   window that shows on screen. Why: a WinForms Form activates itself on
   first show even with the styles retrofitted (measured 2026-08-30); that
   steals the user's focus. NOT topmost: a ring is pinned immediately above
   its own target in z-order every tick (`KeepAboveTarget`). Why: with
   WS_EX_TOPMOST a ring painted over whatever covered its target, so a
   browser in front of a ringed terminal wore the terminal's color.
4. **Never modify other apps' windows.** Win32 calls on windows we did not
   create are read-only (enumerate, rect, class, pid). We only ever set
   state on ring windows we own. Why: mutating foreign windows is how an
   identity tool becomes malware-shaped.
5. **Zero npm runtime dependencies; PowerShell 5.1-compatible syntax.**
   Why: same portability bar as Lane A; nothing to audit, nothing to break.
6. **Fail silent, never intrude.** Rings must never take focus, eat a click,
   or survive their process. Show with SW_SHOWNA only. A crash must leave
   the desktop exactly as it was. Why: an identity overlay that interferes
   with input is worse than no overlay.
7. **Resident budget: under 3% of one core sustained with 10 rings, no
   unbounded memory growth.** Why: it runs all day next to real work.
8. **Everything local.** No network I/O anywhere in this codebase. Never log
   window titles anywhere except local state files; titles can contain
   prompt text and document names.

## Coding Conventions
- Plain Node.js + PowerShell 5.1 (no `&&`, no ternary in ps1).
- Small files, verb_noun function names, no abbreviations.
- Comments: one line, two at most. Say why, never what. Measurement notes and
  incident history belong in `docs/ARCHITECTURE.md`, not in the code. A
  file-header block may run to 3 lines. Any longer block has failed this rule;
  run `node scripts/check-comments.js` with the tests.
- No em dashes in UI strings or commit messages.
- Shared JSON files: exactly ONE writer per file (two read-modify-write
  writers can silently lose an update), atomic writes (temp + rename);
  readers tolerate a missing or torn file by keeping their last state.

## Critical Files
- `src/color.js` - rule 1. Read aura's ARCHITECTURE "The Color Contract"
  before even thinking about it.
- `src/renderer-win.ps1` - rules 3, 4, 6. The spike it grew from is
  `aura/spike/overlay-win.ps1`.
- `src/brain.js` - rules 2, 5. Owns every identity decision.

## Common Mistakes to Avoid
- Showing any overlay through WinForms/WPF (rule 3): it will steal focus
  exactly once, at the worst time, and the bug will not reproduce in tests
  that only check styles after creation.
- Using `GetWindowRect` for ring placement: it includes invisible resize
  borders; use `DWMWA_EXTENDED_FRAME_BOUNDS` (attr 9) or the ring floats.
- Spawning a long-lived child that must outlive a dying process tree with
  plain `spawn`: on Windows it dies with the tree (measured in aura).
  Launchers use the `Start-Process -WindowStyle Hidden` double-hop.
- Ringing a terminal window with no identity: no color in Lane A means no ring
  here, so the brain skips sessions where `hasColor` is not true. Read
  `hasColor`, never `isRepo`: aura colors a named tab too, and that session is
  `isRepo: false`. State written before aura shipped `hasColor` carries only
  `isRepo`, so the check falls back to it.
- Trusting a hwnd across time: handles recycle. Tags and ring entries carry
  hwnd + pid; the renderer verifies the pid still owns the hwnd before
  ringing, and everything is pruned the moment the window or process is
  gone.
