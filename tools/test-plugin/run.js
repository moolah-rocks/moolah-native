#!/usr/bin/env node
// CLI: `node tools/test-plugin/run.js [host ...]`
//
// Runs every fixture under `tools/test-plugin/fixtures/<host>/`. A fixture
// is a triple:
//   <scenario>.html              sanitised page
//   <scenario>.expected.json     expected ImportPayload
//   <scenario>.sanitise.yml      sanitise config (read by sanitise.py)
//
// The matching plugin lives at `Plugins/<host>/parser.js`. The CLI loads
// the plugin into jsdom, captures its `completionFunction` payload, and
// asserts byte-equality (after canonical JSON serialisation) against the
// expected file.
//
// Exit code 0 on full success, 1 on any mismatch / error.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runPlugin, deriveClassName } from "./lib/harness.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "../..");
const PLUGINS_DIR = path.join(REPO, "Plugins");
const FIXTURES_DIR = path.join(HERE, "fixtures");

const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

function listHosts(filter) {
  if (!existsSync(FIXTURES_DIR)) return [];
  return readdirSync(FIXTURES_DIR)
    .filter((entry) => statSync(path.join(FIXTURES_DIR, entry)).isDirectory())
    .filter((host) => filter.length === 0 || filter.includes(host))
    .sort();
}

function listScenarios(host) {
  const dir = path.join(FIXTURES_DIR, host);
  return readdirSync(dir)
    .filter((f) => f.endsWith(".html"))
    .map((f) => f.replace(/\.html$/, ""))
    .sort();
}

function canonicalJSON(value) {
  // Sort keys deterministically so byte-comparison is stable.
  if (Array.isArray(value)) return value.map(canonicalJSON);
  if (value !== null && typeof value === "object") {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = canonicalJSON(value[key]);
    return out;
  }
  return value;
}

function loadParser(host) {
  const file = path.join("Plugins", host, "parser.js");
  const absolute = path.join(REPO, file);
  if (!existsSync(absolute)) {
    throw new Error(`plugin not found: ${file}`);
  }
  return {
    source: readFileSync(absolute, "utf8"),
    className: deriveClassName(`${host}/parser.js`),
  };
}

function loadSourceURL(host, scenario) {
  // Each fixture's sanitise.yml carries a `synthetic_url` line that the
  // harness uses as `location.href`. If absent, fall back to `https://<host>/`.
  const yml = path.join(FIXTURES_DIR, host, `${scenario}.sanitise.yml`);
  if (!existsSync(yml)) return `https://${host}/`;
  const text = readFileSync(yml, "utf8");
  const m = text.match(/^synthetic_url:\s*"?([^"\n]+)"?\s*$/m);
  return m ? m[1].trim() : `https://${host}/`;
}

async function runOne(host, scenario) {
  const htmlPath = path.join(FIXTURES_DIR, host, `${scenario}.html`);
  const expectedPath = path.join(FIXTURES_DIR, host, `${scenario}.expected.json`);

  const html = readFileSync(htmlPath, "utf8");
  const { source: parserSource, className } = loadParser(host);
  const sourceURL = loadSourceURL(host, scenario);

  const payload = await runPlugin({ html, parserSource, className, sourceURL });
  const expected = JSON.parse(readFileSync(expectedPath, "utf8"));

  const actualText = JSON.stringify(canonicalJSON(payload), null, 2);
  const expectedText = JSON.stringify(canonicalJSON(expected), null, 2);

  if (actualText === expectedText) {
    console.log(`${GREEN}  ✓${RESET} ${scenario}`);
    return { pass: true };
  }

  console.log(`${RED}  ✗${RESET} ${scenario}`);
  console.log(`${DIM}    expected: ${expectedPath}${RESET}`);
  // Print a short diff (first 60 lines).
  const expectedLines = expectedText.split("\n");
  const actualLines = actualText.split("\n");
  const max = Math.max(expectedLines.length, actualLines.length);
  let diffShown = 0;
  for (let i = 0; i < max && diffShown < 60; i++) {
    const e = expectedLines[i];
    const a = actualLines[i];
    if (e !== a) {
      if (e !== undefined) console.log(`${RED}    - ${e}${RESET}`);
      if (a !== undefined) console.log(`${GREEN}    + ${a}${RESET}`);
      diffShown++;
    }
  }
  return { pass: false };
}

async function main() {
  const filter = process.argv.slice(2);
  const hosts = listHosts(filter);

  if (hosts.length === 0) {
    if (filter.length > 0) {
      console.error(`No matching fixtures for: ${filter.join(", ")}`);
      process.exit(1);
    }
    console.log("No fixtures present.");
    return;
  }

  let total = 0;
  let failed = 0;
  for (const host of hosts) {
    console.log(`${host}`);
    for (const scenario of listScenarios(host)) {
      total++;
      try {
        const { pass } = await runOne(host, scenario);
        if (!pass) failed++;
      } catch (err) {
        console.log(`${RED}  ✗${RESET} ${scenario} — ${err.message}`);
        failed++;
      }
    }
  }
  const summary = `${total - failed}/${total} passed`;
  if (failed > 0) {
    console.log(`\n${RED}${summary}${RESET}`);
    process.exit(1);
  }
  console.log(`\n${GREEN}${summary}${RESET}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
