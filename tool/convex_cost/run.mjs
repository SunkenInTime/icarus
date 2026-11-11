#!/usr/bin/env node
// Read-cost and write-contention budgets for the cloud library.
//
// Starts a private Convex backend, deploys this checkout's convex/ to it,
// seeds a 150-strategy library, runs the flows in lib/scenarios.mjs with
// the app's live queries subscribed, and compares what the backend billed
// each flow with budgets.json. Fails when a flow got more expensive than
// its budget. See README.md.
//
//   node tool/convex_cost/run.mjs              check against budgets.json
//   node tool/convex_cost/run.mjs --update     write today's numbers there
//   node tool/convex_cost/run.mjs --project <checkout>   deploy another
//                                              checkout's convex/ (to show a
//                                              budget catching an old bug)
//   --only move,agentDrag   --port 3310   --json <file>
//   --url <url> --admin-key <key>   use a running backend instead (it must
//                                   be empty: the scenarios seed it)

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BACKEND_RELEASE, deploy, startBackend } from "./lib/backend.mjs";
import { LogStream } from "./lib/logs.mjs";
import { runScenarios, SCENARIOS } from "./lib/scenarios.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const budgetsPath = join(here, "budgets.json");

function parseArgs(argv) {
  const options = { port: 3310, project: repoRoot, update: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => argv[++i];
    if (arg === "--update") options.update = true;
    else if (arg === "--project") options.project = resolve(value());
    else if (arg === "--port") options.port = Number(value());
    else if (arg === "--only") options.only = value().split(",");
    else if (arg === "--json") options.json = value();
    else if (arg === "--url") options.url = value();
    else if (arg === "--admin-key") options.adminKey = value();
    else throw new Error(`Unknown argument ${arg}`);
  }
  return options;
}

/// Metrics and how much each may grow before the budget fails: a little
/// room over today for byte counts (row sizes drift with harmless schema
/// additions), less for counts, none for write conflicts.
const METRICS = {
  listReruns: { label: "library list re-runs", unit: "", headroom: 0.2 },
  listReadBytes: { label: "bytes read by library list re-runs", unit: "B", headroom: 0.25 },
  readBytes: { label: "bytes read in all", unit: "B", headroom: 0.25 },
  applyBatchReadBytes: { label: "bytes applyBatch read", unit: "B", headroom: 0.25 },
  applyBatchWriteBytes: { label: "bytes applyBatch wrote", unit: "B", headroom: 0.25 },
  liveQueryReruns: { label: "live query re-runs", unit: "", headroom: 0 },
  pageReruns: { label: "page part re-runs", unit: "", headroom: 0 },
  pageReadBytes: { label: "bytes read by page part re-runs", unit: "B", headroom: 0.25 },
  otherReruns: { label: "other live query re-runs", unit: "", headroom: 0 },
  conflictRetries: { label: "write-conflict retries", unit: "", headroom: 0 },
};

function budgetFor(metric, today) {
  const { headroom } = METRICS[metric];
  if (headroom === 0) return today;
  // Counts get at least two more, so a budget near zero isn't a hair trigger.
  const room = METRICS[metric].unit === "B" ? Math.ceil(today * headroom) : Math.max(2, Math.ceil(today * headroom));
  return today + room;
}

const format = (metric, value) =>
  METRICS[metric].unit === "B" ? (value >= 10_000 ? `${(value / 1024).toFixed(1)} KB` : `${value} B`) : String(value);

function printDetail(name, result) {
  const rows = [...result.summary.byFunction.entries()].sort((a, b) => b[1].readBytes - a[1].readBytes);
  console.log(`  ${"function".padEnd(32)} ${"runs".padStart(5)} ${"cached".padStart(6)} ${"read".padStart(10)} ${"written".padStart(10)} ${"retries".padStart(7)}`);
  for (const [fn, row] of rows) {
    console.log(
      `  ${fn.padEnd(32)} ${String(row.runs).padStart(5)} ${String(row.cachedRuns).padStart(6)} ${format("readBytes", row.readBytes).padStart(10)} ${format("readBytes", row.writeBytes).padStart(10)} ${String(row.conflictRetries).padStart(7)}`,
    );
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const budgets = JSON.parse(readFileSync(budgetsPath, "utf8"));
  const names = options.only ?? Object.keys(SCENARIOS);
  const begun = Date.now();

  let backend = null;
  let url = options.url;
  let adminKey = options.adminKey;
  if (!url) {
    backend = await startBackend({ port: options.port });
    ({ url, adminKey } = backend);
    console.log(`Backend ${BACKEND_RELEASE} on ${url}`);
  }
  const logs = new LogStream({ url, adminKey });
  let results;
  try {
    if (backend) {
      const at = Date.now();
      deploy({ url, adminKey, projectDir: options.project });
      console.log(`Deployed ${options.project === repoRoot ? "this checkout" : options.project} in ${((Date.now() - at) / 1000).toFixed(1)} s`);
    }
    logs.start();
    results = await runScenarios({ url, adminKey, projectDir: options.project, logs, names });
  } finally {
    logs.stop();
    await backend?.stop();
  }

  if (options.json) {
    const out = Object.fromEntries(
      Object.entries(results).map(([name, result]) => [
        name,
        { metrics: result.metrics, seconds: result.seconds, byFunction: Object.fromEntries(result.summary.byFunction) },
      ]),
    );
    writeFileSync(options.json, JSON.stringify(out, null, 2));
  }

  const failures = [];
  for (const name of names) {
    const result = results[name];
    const scenario = SCENARIOS[name];
    console.log(`\n${scenario.title} (${name}, ${result.seconds.toFixed(1)} s)`);
    printDetail(name, result);
    for (const problem of result.problems) {
      console.log(`  FAILED ${problem}`);
      failures.push(`${scenario.title}: ${problem}`);
    }
    const saved = budgets.scenarios[name]?.metrics ?? {};
    for (const [metric, value] of Object.entries(result.metrics)) {
      const entry = saved[metric];
      const label = METRICS[metric].label;
      if (!entry) {
        // A metric without a budget would pass whatever it cost.
        console.log(`  OVER ${label}: ${format(metric, value)} (no budget in budgets.json)`);
        failures.push(`${scenario.title}: ${label} has no budget in budgets.json`);
        continue;
      }
      const over = value > entry.budget;
      const change = entry.today === 0 ? (value === 0 ? "" : `, today ${format(metric, entry.today)}`) : `, ${((value / entry.today) * 100).toFixed(0)}% of today's ${format(metric, entry.today)}`;
      console.log(`  ${over ? "OVER" : "ok  "} ${label}: ${format(metric, value)} (budget ${format(metric, entry.budget)}${change})`);
      if (over) {
        const times = entry.today > 0 ? ` (${(value / entry.today).toFixed(1)}x today's ${format(metric, entry.today)})` : ` (today ${format(metric, entry.today)})`;
        failures.push(`${scenario.title}: ${label} ${format(metric, value)}, over the budget of ${format(metric, entry.budget)}${times}`);
      }
    }
  }

  if (options.update) {
    for (const name of names) {
      const metrics = {};
      for (const [metric, value] of Object.entries(results[name].metrics)) {
        metrics[metric] = { today: value, budget: budgetFor(metric, value) };
      }
      budgets.scenarios[name] = { title: SCENARIOS[name].title, about: SCENARIOS[name].about, metrics };
    }
    budgets.backend = BACKEND_RELEASE;
    writeFileSync(budgetsPath, `${JSON.stringify(budgets, null, 2)}\n`);
    console.log(`\nWrote today's numbers to ${budgetsPath}`);
  }

  console.log(`\nTook ${((Date.now() - begun) / 1000).toFixed(1)} s`);
  if (failures.length > 0 && !options.update) {
    for (const failure of failures) console.log(`::error::${failure}`);
    console.log(
      "\nA flow got more expensive. If the cost is the point of the change, run `node tool/convex_cost/run.mjs --update` and say why in the PR.",
    );
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
