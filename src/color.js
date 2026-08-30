"use strict";

// THE COLOR CONTRACT. Lane B inherits this file unchanged. Pure: no I/O.
// Mapping changes are breaking changes (CLAUDE.md rule 7); read
// docs/ARCHITECTURE.md "The Color Contract" first.

const SHADE_COUNT = 4;
const BASE_BRANCHES = new Set(["main", "master"]);

// Frame lightness per shade step. Spread wide so shades stay tellable-apart.
const FRAME_LIGHTNESS = [50, 63, 39, 72];
// Tint lightness per shade step. All inside the dark, readable band.
const TINT_LIGHTNESS = [13, 16, 10, 19];

function fnv1a(text) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

function hslToHex(hue, saturationPct, lightnessPct) {
  const s = saturationPct / 100;
  const l = lightnessPct / 100;
  const k = (n) => (n + hue / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const channel = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  const toHex = (v) => Math.round(v * 255).toString(16).padStart(2, "0");
  return "#" + toHex(channel(0)) + toHex(channel(8)) + toHex(channel(4));
}

// repoId: origin remote URL, else repo root path, else cwd (non-repo session).
// branch: git branch name, or null outside a repo.
function colorsFor({ repoId, branch }) {
  const hue = fnv1a(String(repoId)) % 360;
  const isBase = branch === null || branch === undefined || branch === "" || BASE_BRANCHES.has(branch);
  const shadeIndex = isBase ? 0 : 1 + (fnv1a(String(branch)) % (SHADE_COUNT - 1));
  return {
    hue,
    shadeIndex,
    tintHex: hslToHex(hue, 35, TINT_LIGHTNESS[shadeIndex]),
    frameHex: hslToHex(hue, 70, FRAME_LIGHTNESS[shadeIndex]),
  };
}

module.exports = { colorsFor, fnv1a, hslToHex };
