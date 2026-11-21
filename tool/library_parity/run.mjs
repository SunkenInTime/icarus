#!/usr/bin/env node
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));

export const sizes = {
  ci: { first: 0, seeds: 24, steps: 150 },
  large: { first: 0, seeds: 150, steps: 200 },
};

export const mustReach = {
  "lineup.patch rejected merge_invalid": 5,
  "lineup.patch rejected field_conflict": 3,
  "element.patch rejected field_conflict": 8,
  "element.patch failed PAGE_DELETED": 60,
  "element.delete failed PAGE_DELETED": 15,
  "lineup.patch failed PAGE_DELETED": 60,
  "page.delete applied": 20,
  "page.delete noop": 8,
  "page.add failed PAGE_DELETED": 15,
  "element.add applied": 50,
  "element.add failed INVALID_PAYLOAD": 5,
  "element.add rejected already_exists": 20,
  "element.patch rejected deleted": 60,
  "element.patch applied": 120,
  "lineup.patch applied": 200,
  "strategy.patch applied": 70,
};

export function parseArgs(argv) {
  const value = (flag) => {
    const at = argv.indexOf(flag);
    return at < 0 ? undefined : argv[at + 1];
  };
  const replay = value("--replay");
  if (replay !== undefined) return { replay: resolve(replay) };
  const size = argv.includes("--large") ? sizes.large : sizes.ci;
  const seed = value("--seed");
  const steps = value("--steps");
  const run = { ...size };
  if (steps !== undefined) run.steps = wholeNumber(steps, "--steps");
  if (seed !== undefined) {
    run.first = wholeNumber(seed, "--seed");
    run.seeds = 1;
  }
  const seeds = value("--seeds");
  if (seeds !== undefined) run.seeds = wholeNumber(seeds, "--seeds");
  run.full = seed === undefined && steps === undefined && seeds === undefined;
  run.coverage = run.full || argv.includes("--coverage");
  return run;
}

function wholeNumber(text, flag) {
  const number = Number(text);
  if (!Number.isInteger(number) || number < 0) {
    throw new Error(`${flag} takes a whole number`);
  }
  return number;
}

export function requestedSeeds(run) {
  return Array.from({ length: run.seeds }, (_, index) => run.first + index);
}

export function corpusProblems(seeds, steps, scenarios) {
  const problems = [];
  const found = scenarios.map((scenario) => scenario.seed);
  if (JSON.stringify(found) !== JSON.stringify(seeds)) {
    problems.push(`the generator made seeds ${found.join(",")}, not ${seeds.join(",")}`);
  }
  const sequences = new Map();
  for (const scenario of scenarios) {
    const sequence = JSON.stringify(scenario.ops).replaceAll(`s${scenario.seed}-`, "s-");
    if (sequences.has(sequence)) {
      problems.push(`seeds ${sequences.get(sequence)} and ${scenario.seed} hold the same ops`);
    }
    sequences.set(sequence, scenario.seed);
  }
  for (const scenario of scenarios) {
    if (scenario.ops.length !== steps || scenario.predicted.length !== steps) {
      problems.push(
        `seed ${scenario.seed} has ${scenario.ops.length} ops and ` +
          `${scenario.predicted.length} predictions, not ${steps}`,
      );
    }
  }
  return problems;
}

export function reportProblems(seeds, steps, report) {
  const problems = [];
  const found = report.map((entry) => entry.seed);
  if (JSON.stringify(found) !== JSON.stringify(seeds)) {
    problems.push(`the server compared seeds ${found.join(",")}, not ${seeds.join(",")}`);
  }
  for (const entry of report) {
    if (entry.difference === undefined && entry.compared !== steps) {
      problems.push(`seed ${entry.seed} compared ${entry.compared} ops, not ${steps}`);
    }
  }
  return problems;
}

export function storyProblems(scenarios, report) {
  const problems = [];
  const names = scenarios.map((scenario) => scenario.name);
  const compared = report.map((entry) => entry.name);
  if (JSON.stringify(compared) !== JSON.stringify(names)) {
    problems.push(`the server compared ${compared.length} merge stories and seeds, not ${names.length}`);
  }
  for (const entry of report) {
    if (entry.difference !== undefined) {
      problems.push(
        `${entry.name}, step ${entry.difference.step}: ` +
          `${entry.difference.problem ?? `${entry.difference.op.type} differs`}\n` +
          JSON.stringify(entry.difference, null, 1),
      );
    }
  }
  return problems;
}

export function missingCoverage(outcomes) {
  return Object.entries(mustReach)
    .filter(([outcome, least]) => (outcomes[outcome] ?? 0) < least)
    .map(([outcome, least]) => `${outcome}: ${outcomes[outcome] ?? 0} of at least ${least}`);
}

function dartCommand() {
  return (process.env.DART ?? "dart").split(" ");
}

function dart(args, tool = "tool/parity_scenarios.dart") {
  const [command, ...prefix] = dartCommand();
  execFileSync(command, [...prefix, "run", tool, ...args], {
    cwd: join(root, "packages/icarus_library"),
    stdio: "inherit",
  });
}

function failureFile(scenario, difference) {
  const directory = join(root, "build/library_parity");
  mkdirSync(directory, { recursive: true });
  const file = join(directory, `seed-${scenario.seed}-step-${difference.step}.json`);
  writeFileSync(
    file,
    JSON.stringify(
      {
        seed: scenario.seed,
        steps: difference.step + 1,
        generatedSteps: scenario.steps,
        dartVersion: scenario.dartVersion,
        initial: scenario.initial,
        ops: scenario.ops.slice(0, difference.step + 1),
      },
      null,
      1,
    ),
  );
  return relative(root, file);
}

function main() {
  const run = parseArgs(process.argv.slice(2));
  const work = mkdtempSync(join(tmpdir(), "library-parity-"));
  const scenariosPath = join(work, "scenarios.json");
  const reportPath = join(work, "report.json");
  const storiesPath = join(work, "stories.json");
  const storiesReportPath = join(work, "stories-report.json");
  const rulesPath = join(work, "field_rules.json");
  try {
    let seeds;
    let steps;
    if (run.replay !== undefined) {
      dart(["replay", run.replay, scenariosPath]);
      const recorded = JSON.parse(readFileSync(run.replay, "utf8"));
      seeds = [recorded.seed];
      steps = recorded.ops.length;
      console.log(
        `Replaying seed ${recorded.seed}: ${steps} ops, recorded with Dart ${recorded.dartVersion}`,
      );
    } else {
      dart([
        "generate",
        join(root, "tool/library_parity/samples.json"),
        String(run.first),
        String(run.seeds),
        String(run.steps),
        scenariosPath,
      ]);
      seeds = requestedSeeds(run);
      steps = run.steps;
    }
    const scenarios = JSON.parse(readFileSync(scenariosPath, "utf8"));
    const problems = corpusProblems(seeds, steps, scenarios);
    dart([rulesPath], "tool/field_rules.dart");
    const withStories = run.replay === undefined;
    if (withStories) {
      dart(["stories", join(root, "tool/library_parity/samples.json"), storiesPath]);
    }
    const vitest = spawnSync(
      "npx",
      ["vitest", "run", "--config", "tool/library_parity/vitest.config.ts"],
      {
        cwd: root,
        stdio: "inherit",
        env: {
          ...process.env,
          PARITY_IN: scenariosPath,
          PARITY_OUT: reportPath,
          FIELD_RULES: rulesPath,
          ...(withStories
            ? { PARITY_STORIES: storiesPath, PARITY_STORIES_OUT: storiesReportPath }
            : {}),
        },
      },
    );
    const { scenarios: report, outcomes } = JSON.parse(readFileSync(reportPath, "utf8"));
    problems.push(...reportProblems(seeds, steps, report));
    for (const entry of report.filter((entry) => entry.difference !== undefined)) {
      const scenario = scenarios.find((candidate) => candidate.seed === entry.seed);
      const file = failureFile(scenario, entry.difference);
      problems.push(
        `seed ${entry.seed}, step ${entry.difference.step}: ` +
          `${entry.difference.problem ?? `${entry.difference.op.type} differs`}\n` +
          `${JSON.stringify(entry.difference, null, 1)}\n` +
          `Replay these ops: node tool/library_parity/run.mjs --replay ${file}\n` +
          `Regenerate them: node tool/library_parity/run.mjs --seed ${entry.seed} --steps ${entry.difference.step + 1}`,
      );
    }
    if (run.coverage) problems.push(...missingCoverage(outcomes));
    if (process.argv.includes("--counts")) {
      for (const [outcome, count] of Object.entries(outcomes).sort((a, b) => b[1] - a[1])) {
        console.log(`${String(count).padStart(6)} ${outcome}`);
      }
    }
    let stories = [];
    if (withStories) {
      const named = JSON.parse(readFileSync(storiesPath, "utf8"));
      stories = JSON.parse(readFileSync(storiesReportPath, "utf8")).scenarios;
      problems.push(...storyProblems(named, stories));
    }
    const compared = [...report, ...stories].reduce((total, entry) => total + entry.compared, 0);
    console.log(
      `${compared} ops in ${report.length} seeded sequences and ${stories.length} ` +
        `merge stories and merge seeds matched convex/ops.ts`,
    );
    for (const problem of problems) console.error(problem);
    if (vitest.status !== 0 || problems.length > 0) process.exitCode = 1;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
