#!/usr/bin/env node

// Syntax-check every first-party browser script with the local Node runtime.
// This catches parse errors without requiring npm dependencies.

import { spawnSync } from "node:child_process";
import { readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const roots = ["dxweb/public", "dxweb-admin/admin", "tests/web"];
const skip = new Set(["vendor", "node_modules"]);
const files = [];

function walk(dir) {
  for (const name of readdirSync(dir)) {
    if (skip.has(name)) continue;
    const path = join(dir, name);
    const st = statSync(path);
    if (st.isDirectory()) walk(path);
    else if (/\.(?:js|mjs)$/.test(name)) files.push(path);
  }
}

for (const root of roots) walk(root);
files.sort();

let failed = 0;
for (const file of files) {
  const r = spawnSync(process.execPath, ["--check", file], {
    encoding: "utf8",
  });
  if (r.status !== 0) {
    failed++;
    console.error(`FAIL ${relative(process.cwd(), file)}`);
    console.error(r.stderr.trim());
  }
}

if (failed) {
  console.error(`\n${failed} file(s) failed the syntax check.`);
  process.exit(1);
}
console.log(`Syntax OK: ${files.length} JavaScript files.`);
