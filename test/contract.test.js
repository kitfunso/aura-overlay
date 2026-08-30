"use strict";
// CLAUDE.md rule 1: src/color.js stays byte-identical to aura's copy.
// This test is the enforcement (there is no CI). It compares hashes when the
// aura checkout sits next to this repo, and skips when it does not.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const OURS = path.join(__dirname, "..", "src", "color.js");
const AURA = path.join(__dirname, "..", "..", "aura", "src", "color.js");

function sha1(file) {
  return crypto.createHash("sha1").update(fs.readFileSync(file)).digest("hex");
}

test("color.js is byte-identical to aura's copy (rule 1)", function (t) {
  if (!fs.existsSync(AURA)) {
    t.skip("no sibling aura checkout to compare against");
    return;
  }
  assert.equal(sha1(OURS), sha1(AURA),
    "color.js drifted from aura's copy; changes flow aura -> aura-overlay only");
});
