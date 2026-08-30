"use strict";
// aura-overlay brain: maps visible windows to ring colors, writes
// rings.json for the renderer. Identity ladder and file-ownership
// contract: docs/ARCHITECTURE.md.
const { execFileSync, spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const readline = require("readline");
const { colorsFor } = require("./color.js");

const TERMINAL_PROCESSES = new Set([
  "WindowsTerminal", "OpenConsole", "conhost", "wezterm-gui", "alacritty", "ghostty",
]);
const CYCLE_MS = 2000;
const SCAN_TIMEOUT_MS = 5000;
// Empty by default: a nonempty default rings the wrong windows on a fresh
// install (docs/ARCHITECTURE.md).
const CONFIG_DEFAULTS = { paletteProcesses: [] };

function parse_args(argv) {
  const args = { once: false, parentPid: 0, dir: "", state: "" };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--once") args.once = true;
    else if (a === "--parent-pid") args.parentPid = Number(argv[++i]) || 0;
    else if (a === "--dir") args.dir = argv[++i] || "";
    else if (a === "--state") args.state = argv[++i] || "";
  }
  if (!args.dir) args.dir = path.join(process.env.LOCALAPPDATA || "", "aura-overlay");
  if (!args.state) args.state = path.join(process.env.LOCALAPPDATA || "", "aura", "state.json");
  return args;
}

function read_json(file) {
  try { return { ok: true, value: JSON.parse(fs.readFileSync(file, "utf8")) }; }
  catch (err) { return { ok: false, value: null }; }
}

function write_atomic(file, text) {
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

function parent_alive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (err) { return err.code === "EPERM"; }
}

// Skips off-repo sessions, so a window shared by a repo tab and a bare shell
// keeps the repo's ring (same precedence Lane A gives the window frame).
function newest_session_for_hwnd(state, hwnd) {
  let best = null;
  for (const id of Object.keys(state.sessions || {})) {
    const s = state.sessions[id];
    if (s.hwnd !== hwnd || s.isRepo === false) continue;
    if (!best || String(s.updatedAt) > String(best.updatedAt)) best = s;
  }
  return best;
}

function newest_session(state) {
  let best = null;
  for (const id of Object.keys(state.sessions || {})) {
    const s = state.sessions[id];
    if (!best || String(s.updatedAt) > String(best.updatedAt)) best = s;
  }
  return best;
}

// Newest session at or before tag time (unix ms): stops a session whose
// agent turns AFTER the hotkey from stealing the tag mid-resolution.
function newest_session_at_or_before(state, t) {
  if (!isFinite(t)) return null;
  let best = null;
  for (const id of Object.keys(state.sessions || {})) {
    const s = state.sessions[id];
    if (!(Date.parse(s.updatedAt) <= t)) continue;   // NaN parse also skips
    if (!best || String(s.updatedAt) > String(best.updatedAt)) best = s;
  }
  return best;
}

function tag_key(tag) {
  return String(tag.hwnd) + ":" + String(tag.pid) + ":" + String(tag.taggedAt);
}

// Freeze new tags to the newest session at tag time; fall back to newest
// overall so an early tag still resolves later (docs/ARCHITECTURE.md).
function resolve_tag_identities(tags, state, identities) {
  const next = {};
  let changed = false;
  for (const tag of tags) {
    const key = tag_key(tag);
    if (identities[key]) { next[key] = identities[key]; continue; }
    const session = newest_session_at_or_before(state, Number(tag.taggedAt)) || newest_session(state);
    if (session && session.repoId) {
      next[key] = { repoId: session.repoId, branch: session.branch || null };
      changed = true;
    }
  }
  for (const key of Object.keys(identities)) {
    if (!next[key]) changed = true;
  }
  return { identities: next, changed };
}

function build_rings(windows, state, tags, identities, config) {
  const palette = new Set((config.paletteProcesses || []).map(function (s) { return String(s).toLowerCase(); }));
  const report = [];
  for (const win of windows) {
    let identity = null;
    let source = "";
    const tag = tags.find(function (t) { return t.hwnd === win.hwnd && t.pid === win.pid; });
    if (tag) {
      // a tagged window is the tag's business alone: resolved rings, unresolved waits
      const frozen = identities[tag_key(tag)];
      if (!frozen) continue;
      identity = frozen;
      source = "tag";
    } else if (TERMINAL_PROCESSES.has(win.process)) {
      const session = newest_session_for_hwnd(state, win.hwnd);
      if (session) {
        identity = { repoId: session.repoId, branch: session.branch || null };
        source = "state";
      }
    }
    if (!identity && !tag && palette.has(win.process.toLowerCase())) {
      identity = { repoId: win.process.toLowerCase(), branch: null };
      source = "palette";
    }
    if (!identity) continue;
    const colors = colorsFor(identity);
    report.push({
      hwnd: win.hwnd, pid: win.pid, process: win.process,
      source: source, repoId: identity.repoId, branch: identity.branch,
      hex: colors.frameHex,
    });
  }
  report.sort(function (a, b) { return a.hwnd - b.hwnd; });
  return report;
}

function init_context(args) {
  fs.mkdirSync(args.dir, { recursive: true });
  const configPath = path.join(args.dir, "config.json");
  if (!fs.existsSync(configPath)) {
    write_atomic(configPath, JSON.stringify(CONFIG_DEFAULTS, null, 2) + "\n");
  }
  const identitiesRead = read_json(path.join(args.dir, "tag-identities.json"));
  let lastRingsText = "";
  try { lastRingsText = fs.readFileSync(path.join(args.dir, "rings.json"), "utf8"); } catch (err) {}
  return {
    args: args,
    tags: [],
    identities: (identitiesRead.ok && identitiesRead.value) ? identitiesRead.value : {},
    lastRingsText: lastRingsText,
  };
}

// One decision cycle over an already-scanned window list. Returns the report.
function run_cycle(ctx, windowsRaw) {
  const windows = windowsRaw.filter(function (w) {
    return w && typeof w.hwnd === "number" && typeof w.pid === "number" && w.process;
  });
  const stateRead = read_json(ctx.args.state);
  const state = (stateRead.ok && stateRead.value) ? stateRead.value : { sessions: {} };

  const tagsPath = path.join(ctx.args.dir, "tags.json");
  if (!fs.existsSync(tagsPath)) {
    ctx.tags = [];
  } else {
    const tagsRead = read_json(tagsPath);
    if (tagsRead.ok && Array.isArray(tagsRead.value)) ctx.tags = tagsRead.value;
    // torn read: keep last known tags rather than wrongly pruning identities
  }

  // config.json is user-edited: normalize the shape so a bad edit degrades
  // to defaults for that cycle instead of crashing every cycle (rule 6)
  const configRead = read_json(path.join(ctx.args.dir, "config.json"));
  const configRaw = (configRead.ok && configRead.value && typeof configRead.value === "object")
    ? configRead.value : {};
  const config = {
    paletteProcesses: Array.isArray(configRaw.paletteProcesses)
      ? configRaw.paletteProcesses : CONFIG_DEFAULTS.paletteProcesses,
  };

  const resolved = resolve_tag_identities(ctx.tags, state, ctx.identities);
  ctx.identities = resolved.identities;
  if (resolved.changed) {
    write_atomic(path.join(ctx.args.dir, "tag-identities.json"), JSON.stringify(ctx.identities, null, 2) + "\n");
  }

  const report = build_rings(windows, state, ctx.tags, ctx.identities, config);
  const rings = report.map(function (r) { return { hwnd: r.hwnd, pid: r.pid, hex: r.hex }; });
  const text = JSON.stringify(rings);
  if (text !== ctx.lastRingsText) {
    write_atomic(path.join(ctx.args.dir, "rings.json"), text);
    ctx.lastRingsText = text;
  }
  return report;
}

function scan_once() {
  const script = path.join(__dirname, "detect-win.ps1");
  try {
    const out = execFileSync("powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script],
      { timeout: 30000, windowsHide: true }).toString();
    return JSON.parse(out);
  } catch (err) {
    return null;
  }
}

// Persistent scanner child, reused every cycle: a fresh spawn per cycle
// is too costly (docs/ARCHITECTURE.md). Exits on its own when our stdin closes.
function create_scanner() {
  const script = path.join(__dirname, "detect-win.ps1");
  const child = spawn("powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-Loop"],
    { windowsHide: true, stdio: ["pipe", "pipe", "ignore"] });
  // async EPIPE from a dying scanner surfaces on the stream, not the write
  // call; without a handler it is an uncaught exception that kills the brain
  child.stdin.on("error", function () {});
  const rl = readline.createInterface({ input: child.stdout });
  const pending = [];
  const scanner = { dead: false, child: child };
  function fail_all() {
    scanner.dead = true;
    while (pending.length) { const cb = pending.shift(); cb(null); }
  }
  rl.on("line", function (line) {
    const cb = pending.shift();
    if (cb) cb(line);
  });
  child.on("exit", fail_all);
  child.on("error", fail_all);
  scanner.scan = function (cb) {
    if (scanner.dead) { cb(null); return; }
    let done = false;
    const timer = setTimeout(function () {
      if (done) return;
      done = true;
      scanner.dead = true;
      try { child.kill(); } catch (err) {}
      cb(null);
    }, SCAN_TIMEOUT_MS);
    pending.push(function (line) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (!line) { cb(null); return; }
      try { cb(JSON.parse(line)); } catch (err) { cb(null); }
    });
    try { child.stdin.write("scan\n"); } catch (err) {
      if (!done) { done = true; clearTimeout(timer); scanner.dead = true; cb(null); }
    }
  };
  scanner.close = function () {
    try { child.stdin.end(); } catch (err) {}
    try { child.kill(); } catch (err) {}
  };
  return scanner;
}

function main() {
  const args = parse_args(process.argv);
  let ctx;
  try {
    ctx = init_context(args);
  } catch (err) {
    // startup is the one place rule 6 silence hurts: dying here leaves no
    // rings AND no trace anywhere. One log line, then exit nonzero.
    try {
      fs.appendFileSync(path.join(args.dir, "brain.log"),
        new Date().toISOString() + " init failed: " + (err && err.message ? err.message : err) + "\n");
    } catch (logErr) {}
    process.exit(1);
  }

  if (args.once) {
    const windows = scan_once();
    if (!windows) { console.log("[]"); process.exit(1); }
    const report = run_cycle(ctx, windows);
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  let scanner = create_scanner();
  let busy = false;
  function shutdown() {
    scanner.close();
    process.exit(0);
  }
  function tick() {
    if (args.parentPid && !parent_alive(args.parentPid)) { shutdown(); return; }
    if (busy) return;
    if (scanner.dead) scanner = create_scanner();
    busy = true;
    scanner.scan(function (windows) {
      busy = false;
      if (!windows) return;                 // failed scan: keep last rings
      try { run_cycle(ctx, windows); } catch (err) {}  // fail silent (rule 6)
    });
  }
  setInterval(tick, CYCLE_MS);
  tick();                                   // first rings fast, not after 2 s
}

module.exports = {
  CONFIG_DEFAULTS: CONFIG_DEFAULTS,
  parse_args: parse_args,
  newest_session: newest_session,
  newest_session_at_or_before: newest_session_at_or_before,
  resolve_tag_identities: resolve_tag_identities,
  build_rings: build_rings,
  tag_key: tag_key,
};

if (require.main === module) main();
