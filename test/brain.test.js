"use strict";
// Unit tests for the brain's pure decision logic (no I/O, no child
// processes). Run from the repo root: node --test test/
const test = require("node:test");
const assert = require("node:assert/strict");
const brain = require("../src/brain.js");
const { colorsFor } = require("../src/color.js");

const T0 = Date.parse("2026-08-30T10:00:00.000Z");
function iso(ms) { return new Date(ms).toISOString(); }

const CONFIG = { paletteProcesses: ["chrome", "slack"] };

test("the shipped palette default is empty", function () {
  // A non-empty default rings apps the user never asked for: with no terminal
  // session seen yet, the only rings on screen were the browser's.
  assert.deepEqual(brain.CONFIG_DEFAULTS.paletteProcesses, []);
});

test("parse_args reads flags and zeroes a bad parent pid", function () {
  const a = brain.parse_args(["node", "brain.js", "--once",
    "--parent-pid", "123", "--dir", "D:\\x", "--state", "D:\\s.json"]);
  assert.equal(a.once, true);
  assert.equal(a.parentPid, 123);
  assert.equal(a.dir, "D:\\x");
  assert.equal(a.state, "D:\\s.json");
  const b = brain.parse_args(["node", "brain.js", "--parent-pid", "abc"]);
  assert.equal(b.parentPid, 0);
  assert.equal(b.once, false);
});

test("newest_session picks the latest updatedAt and handles empty state", function () {
  assert.equal(brain.newest_session({}), null);
  const state = { sessions: {
    a: { repoId: "alpha", updatedAt: iso(T0) },
    b: { repoId: "bravo", updatedAt: iso(T0 + 5000) },
  } };
  assert.equal(brain.newest_session(state).repoId, "bravo");
});

test("newest_session_at_or_before ignores sessions updated after t", function () {
  const state = { sessions: {
    a: { repoId: "alpha", updatedAt: iso(T0) },
    b: { repoId: "bravo", updatedAt: iso(T0 + 5000) },
  } };
  assert.equal(brain.newest_session_at_or_before(state, T0 + 1000).repoId, "alpha");
  assert.equal(brain.newest_session_at_or_before(state, T0 + 5000).repoId, "bravo");
  assert.equal(brain.newest_session_at_or_before(state, T0 - 1), null);
  assert.equal(brain.newest_session_at_or_before(state, NaN), null);
});

test("a session that turns after the hotkey cannot steal a new tag", function () {
  const tag = { hwnd: 10, pid: 20, taggedAt: T0 + 500 };
  const state = { sessions: {
    mine: { repoId: "alpha", updatedAt: iso(T0) },
    thief: { repoId: "bravo", updatedAt: iso(T0 + 1000) },  // turned after the hotkey
  } };
  const r = brain.resolve_tag_identities([tag], state, {});
  assert.equal(r.identities[brain.tag_key(tag)].repoId, "alpha");
  assert.equal(r.changed, true);
});

test("a tag placed before any session falls back to newest overall", function () {
  const tag = { hwnd: 10, pid: 20, taggedAt: T0 - 60000 };
  const state = { sessions: {
    only: { repoId: "bravo", branch: "main", updatedAt: iso(T0) },
  } };
  const r = brain.resolve_tag_identities([tag], state, {});
  const frozen = r.identities[brain.tag_key(tag)];
  assert.equal(frozen.repoId, "bravo");
  assert.equal(frozen.branch, "main");
});

test("an already-frozen identity never changes", function () {
  const tag = { hwnd: 10, pid: 20, taggedAt: T0 };
  const key = brain.tag_key(tag);
  const prior = {};
  prior[key] = { repoId: "old", branch: null };
  const state = { sessions: { n: { repoId: "new", updatedAt: iso(T0 + 9000) } } };
  const r = brain.resolve_tag_identities([tag], state, prior);
  assert.equal(r.identities[key].repoId, "old");
  assert.equal(r.changed, false);
});

test("no session at all leaves the tag unresolved and unchanged", function () {
  const tag = { hwnd: 10, pid: 20, taggedAt: T0 };
  const r = brain.resolve_tag_identities([tag], { sessions: {} }, {});
  assert.equal(Object.keys(r.identities).length, 0);
  assert.equal(r.changed, false);
});

test("identities for removed tags are pruned and flagged changed", function () {
  const r = brain.resolve_tag_identities([], { sessions: {} },
    { "1:2:3": { repoId: "x", branch: null } });
  assert.equal(Object.keys(r.identities).length, 0);
  assert.equal(r.changed, true);
});

test("build_rings ladder: tag > terminal session > palette > nothing", function () {
  const tag = { hwnd: 1, pid: 11, taggedAt: T0 };
  const identities = {};
  identities[brain.tag_key(tag)] = { repoId: "frozen-repo", branch: "main" };
  const state = { sessions: {
    s1: { repoId: "term-repo", branch: null, updatedAt: iso(T0), hwnd: 2 },
  } };
  const windows = [
    { hwnd: 4, pid: 44, process: "chrome" },           // palette
    { hwnd: 1, pid: 11, process: "notepad" },          // tagged
    { hwnd: 2, pid: 22, process: "WindowsTerminal" },  // session on hwnd
    { hwnd: 5, pid: 55, process: "explorer" },         // nothing
  ];
  const report = brain.build_rings(windows, state, [tag], identities, CONFIG);
  assert.deepEqual(
    report.map(function (r) { return [r.hwnd, r.source, r.repoId]; }),
    [[1, "tag", "frozen-repo"], [2, "state", "term-repo"], [4, "palette", "chrome"]]);
  assert.equal(report[0].hex,
    colorsFor({ repoId: "frozen-repo", branch: "main" }).frameHex);
});

test("a tagged window with an unresolved identity gets no ring at all", function () {
  const tag = { hwnd: 1, pid: 11, taggedAt: T0 };
  // process would match the palette; the tag must still block the ring
  const windows = [{ hwnd: 1, pid: 11, process: "chrome" }];
  const report = brain.build_rings(windows, { sessions: {} }, [tag], {}, CONFIG);
  assert.equal(report.length, 0);
});

test("no repo, no ring: an off-repo terminal session is skipped", function () {
  const state = {
    sessions: { s: { repoId: "C:/Users/x/notes", branch: null, isRepo: false, updatedAt: iso(T0), hwnd: 7 } },
  };
  const report = brain.build_rings(
    [{ hwnd: 7, pid: 70, process: "WindowsTerminal" }], state, [], {}, CONFIG);
  assert.equal(report.length, 0);
});

test("a repo tab outranks a newer bare shell in the same window", function () {
  const state = {
    sessions: {
      repo: { repoId: "r", branch: "main", isRepo: true, updatedAt: iso(T0), hwnd: 7 },
      shell: { repoId: "C:/Users/x", branch: null, isRepo: false, updatedAt: iso(T0 + 1000), hwnd: 7 },
    },
  };
  const report = brain.build_rings(
    [{ hwnd: 7, pid: 70, process: "WindowsTerminal" }], state, [], {}, CONFIG);
  assert.deepEqual(report.map(function (r) { return [r.hwnd, r.repoId]; }), [[7, "r"]]);
});
