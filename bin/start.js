"use strict";
// aura-overlay launcher.
//   node bin/start.js         start the resident app (renderer + brain), print the pid
//   node bin/start.js --stop  write stop.flag; the renderer quits within a tick
// The renderer launches through the Start-Process double-hop: children of a
// dying process tree die with it on Windows (measured in aura), so the
// renderer must be created by a process outside this one's tree. The
// renderer then spawns the brain itself.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const RUNTIME_DIR = path.join(process.env.LOCALAPPDATA || "", "aura-overlay");
const RENDERER = path.join(__dirname, "..", "src", "renderer-win.ps1");

function write_stop_flag() {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  fs.writeFileSync(path.join(RUNTIME_DIR, "stop.flag"), "stop\n");
  console.log("stop.flag written; the renderer quits within a tick");
}

function start_renderer() {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  // a stale flag from a --stop with nothing running must not kill this start
  try { fs.unlinkSync(path.join(RUNTIME_DIR, "stop.flag")); } catch (err) {}
  const rendererQuoted = "'" + RENDERER.replace(/'/g, "''") + "'";
  const command =
    "$p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File'," + rendererQuoted + "); " +
    "Start-Sleep -Milliseconds 900; " +
    "if ($p.HasExited) { Write-Output ('exited ' + $p.Id) } else { Write-Output ('running ' + $p.Id) }";
  let out;
  try {
    out = execFileSync("powershell.exe", ["-NoProfile", "-Command", command],
      { windowsHide: true, timeout: 15000 }).toString().trim();
  } catch (err) {
    console.log("could not launch the renderer: " + (err && err.message ? err.message : err));
    console.log("check that powershell.exe is on PATH, then retry");
    process.exitCode = 1;
    return;
  }
  if (out.indexOf("running ") === 0) {
    console.log("renderer pid " + out.slice("running ".length));
  } else if (out.indexOf("exited ") === 0) {
    console.log("renderer exited at once (already running? see renderer.log); pid was " + out.slice("exited ".length));
  } else {
    console.log(out);
  }
}

if (process.argv.indexOf("--stop") >= 0) write_stop_flag();
else start_renderer();
