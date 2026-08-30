"use strict";

// The comment budget from CLAUDE.md, made checkable: comments say WHY in one
// or two lines, and only a file header may run to three.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const DIRS = ["src", "bin", "test", "scripts"];
const MAX_LINES = 2;
const MAX_HEADER_LINES = 3;
// A header sits at the top, but "use strict" and a blank line may precede it.
const HEADER_STARTS_BY = 5;

function commentPrefix(file) {
  if (file.endsWith(".js")) return "//";
  if (file.endsWith(".ps1")) return "#";
  return null;
}

function listFiles(dir) {
  const out = [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (err) {
    return out;
  }
  entries.forEach(function (entry) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listFiles(full));
    else if (commentPrefix(entry.name)) out.push(full);
  });
  return out;
}

function findLongBlocks(text, prefix) {
  const lines = text.split(/\r?\n/);
  const blocks = [];
  let start = 0;
  let length = 0;
  const flush = () => {
    if (length > 1) blocks.push({ start, length });
    length = 0;
  };
  lines.forEach(function (line, index) {
    if (line.trim().indexOf(prefix) === 0) {
      if (length === 0) start = index + 1;
      length++;
    } else {
      flush();
    }
  });
  flush();
  return blocks.filter(function (block, index) {
    const isHeader = index === 0 && block.start <= HEADER_STARTS_BY;
    return block.length > (isHeader ? MAX_HEADER_LINES : MAX_LINES);
  });
}

function main() {
  const failures = [];
  DIRS.forEach(function (dir) {
    listFiles(path.join(ROOT, dir)).forEach(function (file) {
      const prefix = commentPrefix(file);
      const text = fs.readFileSync(file, "utf8");
      findLongBlocks(text, prefix).forEach(function (block) {
        const rel = path.relative(ROOT, file).split(path.sep).join("/");
        failures.push(`${rel}:${block.start} - ${block.length} comment lines`);
      });
    });
  });
  if (failures.length) {
    console.error(`comment budget: ${failures.length} block(s) over the limit`);
    failures.forEach((line) => console.error("  " + line));
    console.error(`limit: ${MAX_LINES} lines, ${MAX_HEADER_LINES} for a file header (CLAUDE.md)`);
    process.exit(1);
  }
  console.log("comment budget: ok");
}

main();
