#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));

const sizes = {
  ci: { first: 0, seeds: 24, steps: 150 },
  large: { first: 0, seeds: 150, steps: 200 },
};

const mustReach = [
  "lineup.patch rejected merge_invalid",
  "lineup.patch rejected field_conflict",
  "element.patch rejected field_conflict",
  "element.patch failed PAGE_DELETED",
  "element.delete failed PAGE_DELETED",
  "page.delete applied",
  "page.delete noop",
  "page.add failed PAGE_DELETED",
  "element.add applied",
  "element.patch rejected deleted",
];

export function parseArgs(argv) {
  const seedAt = argv.indexOf("--seed");
  if (seedAt >= 0) {
    const seed = Number(argv[seedAt + 1]);
    if (!Number.isInteger(seed)) throw new Error("--seed takes a whole number");
    const steps = argv.includes("--large") ? sizes.large.steps : sizes.ci.steps;
    return { first: seed, seeds: 1, steps, replay: true };
  }
  const size = argv.includes("--large") ? sizes.large : sizes.ci;
  return { ...size, replay: false };
}

export function missingCoverage(outcomes) {
  return mustReach.filter((outcome) => !(outcomes[outcome] > 0));
}

function main() {
  const run = parseArgs(process.argv.slice(2));
  const dart = (process.env.DART ?? "dart").split(" ");
  const work = mkdtempSync(join(tmpdir(), "library-parity-"));
  const scenarios = join(work, "scenarios.json");
  const report = join(work, "report.json");
  const rules = join(work, "field_rules.json");
  try {
    execFileSync(
      dart[0],
      [
        ...dart.slice(1),
        "run",
        "tool/parity_scenarios.dart",
        String(run.first),
        String(run.seeds),
        String(run.steps),
        scenarios,
      ],
      { cwd: join(root, "packages/icarus_library"), stdio: "inherit" },
    );
    execFileSync(
      dart[0],
      [...dart.slice(1), "run", "tool/field_rules.dart", rules],
      { cwd: join(root, "packages/icarus_library"), stdio: "inherit" },
    );
    const vitest = spawnSync(
      "npx",
      ["vitest", "run", "--config", "tool/library_parity/vitest.config.ts"],
      {
        cwd: root,
        stdio: "inherit",
        env: {
          ...process.env,
          PARITY_IN: scenarios,
          PARITY_OUT: report,
          FIELD_RULES: rules,
        },
      },
    );
    const { scenarios: results, outcomes } = JSON.parse(
      readFileSync(report, "utf8"),
    );
    const differences = results.filter((result) => result.ok === undefined);
    for (const difference of differences) {
      console.error(
        difference.step === undefined
          ? `${difference.name}: the server did not do what the story expects`
          : `${difference.name}, step ${difference.step}: ${difference.op.type} differs` +
            (difference.seed === undefined
              ? ""
              : `. Replay with: node tool/library_parity/run.mjs --seed ${difference.seed}`),
      );
      console.error(JSON.stringify(difference, null, 1));
    }
    const stories = results.filter(
      (result) => !result.name.startsWith("seed "),
    ).length;
    const ops = results.reduce((total, result) => total + (result.ok ?? 0), 0);
    console.log(
      `${ops} ops in ${results.length} sequences, ${stories} of them merge stories, matched convex/ops.ts` +
        (differences.length > 0 ? `; ${differences.length} sequences differ` : ""),
    );
    const missing = run.replay ? [] : missingCoverage(outcomes);
    for (const outcome of missing) {
      console.error(`The run never reached: ${outcome}`);
    }
    if (vitest.status !== 0 || differences.length > 0 || missing.length > 0) {
      process.exitCode = 1;
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
